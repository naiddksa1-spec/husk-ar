#!/usr/bin/env python3
"""Offline regression checks for the rebuilt Husk security boundaries."""
from __future__ import annotations

import ast
import importlib.util
import json
import plistlib
import re
import subprocess
import struct
import sys
import tarfile
import tempfile
import textwrap
from io import BytesIO
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "src/app/Husk"
ASSETS = APP / "Assets.xcassets"


def load_extractor():
    path = ROOT / "scripts/safe_extract_tar.py"
    spec = importlib.util.spec_from_file_location("husk_safe_extract", path)
    if spec is None or spec.loader is None:
        raise AssertionError("cannot load safe tar extractor")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def cloud_init_content(path: str) -> str:
    text = (ROOT / "scripts/cloud-init/user-data").read_text()
    start = text.index(f"  - path: {path}\n")
    marker = "    content: |\n"
    content_start = text.index(marker, start) + len(marker)
    content_end = text.find("\n  - path:", content_start)
    if content_end < 0:
        content_end = len(text)
    return textwrap.dedent(text[content_start:content_end]).rstrip() + "\n"


def make_tar(path: Path, entries: list[tuple[str, str, bytes]]) -> None:
    with tarfile.open(path, "w:gz") as archive:
        for name, kind, payload in entries:
            info = tarfile.TarInfo(name)
            if kind == "file":
                info.size = len(payload)
                archive.addfile(info, BytesIO(payload))
            elif kind == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = payload.decode()
                archive.addfile(info)
            else:
                raise AssertionError(kind)


def check_safe_extractor() -> None:
    module = load_extractor()
    with tempfile.TemporaryDirectory(prefix="husk-sec-") as temp:
        root = Path(temp)
        good_archive, good_dest = root / "good.tar.gz", root / "good"
        good_dest.mkdir()
        make_tar(good_archive, [("source/include/husk.h", "file", b"safe")])
        module.safe_extract(good_archive, good_dest)
        assert (good_dest / "source/include/husk.h").read_bytes() == b"safe"

        bad_archive, bad_dest = root / "bad.tar.gz", root / "bad"
        bad_dest.mkdir()
        make_tar(bad_archive, [("../../outside", "file", b"no")])
        try:
            module.safe_extract(bad_archive, bad_dest)
        except module.UnsafeArchive:
            pass
        else:
            raise AssertionError("path traversal archive was accepted")
        assert not (root.parent / "outside").exists()

        link_archive, link_dest = root / "link.tar.gz", root / "link"
        link_dest.mkdir()
        make_tar(link_archive, [("escape", "symlink", b"../../outside")])
        try:
            module.safe_extract(link_archive, link_dest)
        except module.UnsafeArchive:
            pass
        else:
            raise AssertionError("escaping symlink was accepted")

        # Model a size bomb with a tiny archive: hardlinks are materialized
        # copies by this extractor and must count against expanded output.
        module.MAX_MEMBERS = 8
        module.MAX_UNPACKED_BYTES = 10
        hard_archive, hard_dest = root / "hard.tar.gz", root / "hard"
        hard_dest.mkdir()
        with tarfile.open(hard_archive, "w:gz") as archive:
            payload = b"123456"
            original = tarfile.TarInfo("base.bin")
            original.size = len(payload)
            archive.addfile(original, BytesIO(payload))
            for name in ("copy-1.bin", "copy-2.bin"):
                link = tarfile.TarInfo(name)
                link.type = tarfile.LNKTYPE
                link.linkname = "base.bin"
                archive.addfile(link)
        try:
            module.safe_extract(hard_archive, hard_dest)
        except module.UnsafeArchive as error:
            assert "expanded size limit" in str(error)
        else:
            raise AssertionError("hardlink-expanded size limit was bypassed")
        assert not any(hard_dest.iterdir()), "rejected archive wrote partial output"

def check_network_and_shell_boundaries() -> None:
    plist = plistlib.loads((APP / "Info.plist").read_bytes())
    assert "NSAppTransportSecurity" not in plist
    assert plist.get("CFBundleShortVersionString") == "0.9.1"

    app_source = (APP / "AppSource.swift").read_text()
    assert 'components.scheme?.lowercased() == "https"' in app_source
    assert "maxIndexBytes = 64 * 1024 * 1024" in app_source
    assert "maxAPKBytes: Int64 = 2 * 1024 * 1024 * 1024" in app_source
    assert "response.url?.scheme?.lowercased() == \"https\"" in app_source

    bridge = (APP / "HuskBridgeFS.swift").read_text()
    assert "HuskInputValidation.packageName(pkg)" in bridge
    assert "HuskInputValidation.packageName(package)" in bridge
    assert "replacingOccurrences(of: \"'\", with: \"'\\\\''\")" in bridge
    assert "pm uninstall \\(package)" not in bridge
    assert "monkey -p \\(pkg)" not in bridge
    assert "BundleUnpacker.hasZIPSignature(at: url)" in bridge

    runner = (APP / "QemuRunner.swift").read_text()
    assert "hostfwd=tcp:127.0.0.1:5599-:5599" in runner
    assert "5555" not in runner

    cloud = (ROOT / "scripts/cloud-init/user-data").read_text()
    assert "disable_root: true" in cloud
    assert "ssh_pwauth: false" in cloud
    assert "plain_text_passwd: husk" not in cloud
    assert "curl -fsSL https://repo.waydro.id | bash" not in cloud
    assert "trixie-backports" in cloud and "-t trixie-backports waydroid" in cloud

    agent = cloud_init_content("/usr/local/bin/husk-agent.py")
    tree = ast.parse(agent)
    functions = {node.name: node for node in tree.body if isinstance(node, ast.FunctionDef)}
    assert "valid_package_name" in functions and "run_argv" in functions
    helper = functions["valid_package_name"]
    namespace = {"re": re}
    exec(compile(ast.Module(body=[helper], type_ignores=[]), "husk-agent.py", "exec"), namespace)
    validate = namespace["valid_package_name"]
    assert validate("com.example.game")
    for unsafe in (None, "com.bad;id", "com.bad'$(id)", "com..bad", "éxample.app", "a" * 260):
        assert not validate(unsafe), f"unsafe package accepted: {unsafe!r}"
    assert 'subprocess.run(args, shell=False' in agent
    assert 'run_argv(["waydroid", "app", "launch", pkg]' in agent
    assert 'run_argv(["waydroid", "app", "install", path]' in agent
    assert 'run(f"waydroid app launch {pkg}")' not in agent

    provision = cloud_init_content("/usr/local/bin/husk-provision.sh")
    firstboot = cloud_init_content("/usr/local/bin/husk-firstboot.sh")
    assert "waydroid init ||" not in firstboot
    assert "unzip -tq system.zip" in firstboot
    assert firstboot.rindex("waydroid init") < firstboot.index("touch /var/lib/husk-setup-complete.tmp")
    assert "Restart=on-failure" in cloud and "RestartSec=30" in cloud
    for embedded_script in (provision, firstboot):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".sh") as script:
            script.write(embedded_script)
            script.flush()
            subprocess.run(["bash", "-n", script.name], check=True)

    source_manager = (APP / "AppSource.swift").read_text()
    assert "downloadErrors" in source_manager and "cancelDownload(bundleIdentifier:" in source_manager
    assert "guard sourceURLs.contains(urlString) else { return }" in source_manager
    discover = (APP / "DiscoverTab.swift").read_text()
    assert "No Apps Found" in discover and "Clear Search" in discover
    assert "manager.removeSource(urlString: $0)" in discover

    host = (APP / "HuskBridgeFS.swift").read_text()
    assert "let operationID = UUID().uuidString.lowercased()" in host
    assert "func launch(_ pkg: String" in host and "result.status == 0" in host
    assert "then()" in host and "Could not open app" in host
    runtime = (APP / "TranslationLayer.swift").read_text()
    assert "hasArm64WithoutDriver" in runtime
    assert '.disabled(app.report?.nativeEngine == nil)' in runtime
    assert "No native driver" in runtime


def check_zip_and_build_guards() -> None:
    unpacker = (APP / "BundleUnpacker.swift").read_text()
    for invariant in ("maxDirectoryBytes", "maxEntries", "maxAPKBytes", "maxTotalAPKBytes",
                      "0x0201_4b50", "0x0403_4b50", "crc32(", "entry.localOffset"):
        assert invariant in unpacker, f"missing ZIP guard: {invariant}"
    fetch = (ROOT / "scripts/fetch_sources.sh").read_text()
    assert "safe_extract_tar.py" in fetch
    assert "tar -xf" not in fetch
    phase0 = (ROOT / "scripts/fetch_phase0_guest.sh").read_text()
    assert "safe_extract_tar.py" in phase0
    assert "tar -xf" not in phase0
    preflight = (ROOT / "scripts/build_ios.sh").read_text()
    assert 'uname -s' in preflight and '!= "Darwin"' in preflight


def check_asset_catalog() -> None:
    for icon_set in [p for p in ASSETS.iterdir() if p.is_dir() and p.name.endswith(".appiconset")]:
        metadata = json.loads((icon_set / "Contents.json").read_text())
        for item in metadata["images"]:
            path = icon_set / item["filename"]
            data = path.read_bytes()
            assert data[:8] == b"\x89PNG\r\n\x1a\n", f"bad PNG: {path}"
            width, height = struct.unpack(">II", data[16:24])
            assert (width, height) == (1024, 1024), f"wrong icon size: {path}"
    for name in ("icon-default", "icon-dark", "icon-clearlight", "icon-cleardark",
                 "icon-tintedlight", "icon-tinteddark"):
        folder = ASSETS / f"{name}.imageset"
        metadata = json.loads((folder / "Contents.json").read_text())
        for item in metadata["images"]:
            assert (folder / item["filename"]).is_file()


def main() -> int:
    checks = [check_safe_extractor, check_network_and_shell_boundaries,
              check_zip_and_build_guards, check_asset_catalog]
    for check in checks:
        check()
        print(f"ok   {check.__name__}")
    print(f"passed {len(checks)} security regression groups")
    return 0


if __name__ == "__main__":
    sys.exit(main())
