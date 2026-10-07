#!/usr/bin/env python3
"""Run the actual Swift bundle reader against valid and hostile ZIP files on macOS."""
import pathlib
import shutil
import struct
import subprocess
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
if not shutil.which("swift"):
    raise SystemExit("Swift is required. Run this test on a Mac with Xcode.")
with tempfile.TemporaryDirectory() as temporary:
    root = pathlib.Path(temporary)
    program = root / "main.swift"
    program.write_text((ROOT / "src/app/Husk/BundleUnpacker.swift").read_text() + '''
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
do {
    let names = try BundleUnpacker.unpack(source, into: output)
    print(names.joined(separator: ","))
} catch {
    let remains = try FileManager.default.contentsOfDirectory(atPath: output.path)
    if !remains.isEmpty { exit(2) }
    exit(1)
}
''')
    executable = root / "reader"
    subprocess.run(["swiftc", str(program), "-o", str(executable)], check=True)
    def archive(name, entries):
        target = root / name
        with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_STORED) as output:
            for entry, data in entries:
                output.writestr(entry, data)
        return target
    good = archive("good.zip", [("base.apk", b"PK\x03\x04payload")])
    traversal = archive("traversal.zip", [("../base.apk", b"payload")])
    duplicate = archive("duplicate.zip", [("a/base.apk", b"one"), ("b/BASE.apk", b"two")])
    damaged = root / "damaged.zip"
    data = bytearray(good.read_bytes())
    data[30 + len("base.apk")] ^= 1
    damaged.write_bytes(data)
    invalid_header = root / "invalid-header.zip"
    data = bytearray(good.read_bytes())
    data[:4] = b"NOPE"
    invalid_header.write_bytes(data)
    truncated = root / "truncated.zip"
    truncated.write_bytes(good.read_bytes()[:-7])
    excessive = root / "excessive.zip"
    data = bytearray(good.read_bytes())
    struct.pack_into("<I", data, len(data) - 22 + 12, 0x10000000)
    excessive.write_bytes(data)
    for index, (source, expected) in enumerate([(good, 0), (traversal, 1),
            (duplicate, 1), (damaged, 1), (invalid_header, 1), (truncated, 1), (excessive, 1)]):
        destination = root / f"out-{index}"
        result = subprocess.run([str(executable), str(source), str(destination)], capture_output=True)
        assert result.returncode == expected, (source.name, result.returncode, result.stderr)
        if expected == 0:
            assert (destination / "base.apk").read_bytes() == b"PK\x03\x04payload"
        print("PASS", source.name)