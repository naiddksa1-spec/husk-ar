#!/usr/bin/env python3
"""Portable parser regression checks; not a replacement for an iOS build."""
from pathlib import Path
import io
import os
import random
import shutil
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def archive(name, data, compression=zipfile.ZIP_STORED):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", compression=compression) as z:
        z.writestr(name, data)
    return stream.getvalue()

def dex_fixture():
    # A minimal DEX defining test/A. Checksum/signature are not used by the
    # name index, which is not a full DEX verifier.
    data = bytearray(170)
    data[:8] = b"dex\n035\0"
    for off, value in {0x20:170, 0x24:112, 0x28:0x12345678,
                       0x38:1, 0x3c:112, 0x40:1, 0x44:116,
                       0x60:1, 0x64:120}.items():
        struct.pack_into("<I", data, off, value)
    struct.pack_into("<I", data, 112, 152)
    struct.pack_into("<I", data, 128, 0xffffffff)
    data[152:162] = b"\x08Ltest/A;\0"
    return bytes(data)

def main():
    cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc")
    if not cc:
        raise SystemExit("C compiler required")
    with tempfile.TemporaryDirectory(prefix="ios-app-tests-") as temp:
        temp = Path(temp)
        binary = temp / "parser"
        flags = ["-std=c11", "-Wall", "-Wextra", "-Werror", "-g",
                 "-fsanitize=undefined", "-fno-sanitize-recover=all"]
        if os.environ.get("ASAN") == "1":
            flags.append("-fsanitize=address")
        subprocess.run([cc, *flags, "-I", str(ROOT/"src/translation-layer"),
            "-I", str(ROOT/"src/translation-layer-next"),
            str(ROOT/"tests/parser_harness.c"),
            str(ROOT/"src/translation-layer/husk-tl-zip.c"),
            str(ROOT/"src/translation-layer-next/husk-tl-dexindex.c"),
            "-lz", "-o", str(binary)], check=True)
        checks = 0
        def check(mode, content, expected=None):
            nonlocal checks
            path = temp / "input.apk"
            path.write_bytes(content)
            run = subprocess.run([str(binary), mode, str(path)], capture_output=True, timeout=5)
            assert run.returncode in (0, 1), (run.returncode, run.stderr.decode(errors="replace"))
            assert b"runtime error:" not in run.stderr, run.stderr
            if expected is not None:
                assert (run.returncode == 0) == expected, (mode, run.stdout, run.stderr)
            checks += 1

        for compression in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            for content in (b"", b"hello", b"x" * 65536):
                check("zip", archive("asset.bin", content, compression), True)
        good = archive("asset.bin", b"hello")
        broken = bytearray(good)
        broken[30 + len("asset.bin")] ^= 1
        check("zip", bytes(broken), False)  # stored CRC
        broken = bytearray(good)
        broken[30] ^= 1
        check("zip", bytes(broken), False)  # local/central filename disagreement
        check("zip", good + b"trailing junk", False)
        check("zip", b"not a zip", False)
        dex = dex_fixture()
        check("dex", archive("classes.dex", dex), True)
        for malformed in (b"", b"dex\n035\0", dex[:64],
                          dex[:40] + b"\xff" * 4 + dex[44:]):
            check("dex", archive("classes.dex", malformed), False)
        malformed = bytearray(dex)
        struct.pack_into("<I", malformed, 0x60, 0xffffffff)
        check("dex", archive("classes.dex", malformed), False)
        malformed = bytearray(dex)
        struct.pack_into("<I", malformed, 112, len(malformed)-1)
        malformed[-1] = 0xff
        check("dex", archive("classes.dex", malformed))  # truncated ULEB
        malformed = bytearray(dex)
        struct.pack_into("<I", malformed, 144, len(malformed)-1)
        malformed[-1] = 0xff
        check("dex", archive("classes.dex", malformed))  # malformed class_data
        rng = random.Random(6062)
        for i in range(300):
            mutated = bytearray(dex)
            for _ in range(rng.randint(1, 8)):
                mutated[rng.randrange(len(mutated))] = rng.randrange(256)
            check("dex", archive("classes.dex", mutated))
        for i in range(300):
            mutated = bytearray(good)
            for _ in range(rng.randint(1, 8)):
                mutated[rng.randrange(len(mutated))] = rng.randrange(256)
            check("zip", mutated)
        sanitizers = "ASan + UBSan" if os.environ.get("ASAN") == "1" else "UBSan"
        print(f"PASS: {checks} parser regression/mutation inputs, {sanitizers} enabled.")
        print("NOT TESTED: Swift typechecking, Xcode linking, signing, iPhone runtime, remote dependencies.")

if __name__ == "__main__":
    main()
