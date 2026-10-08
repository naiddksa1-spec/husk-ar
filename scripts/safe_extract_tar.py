#!/usr/bin/env python3
"""Extract a source tarball without trusting archive paths, links, or sizes."""
from __future__ import annotations

import os
import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath

MAX_MEMBERS = 250_000
MAX_UNPACKED_BYTES = 16 * 1024**3
COPY_CHUNK = 1024 * 1024


class UnsafeArchive(ValueError):
    pass


def member_path(name: str) -> str:
    if not name or "\x00" in name or "\\" in name or name.startswith("/"):
        raise UnsafeArchive(f"unsafe archive path: {name!r}")
    raw_parts = name.split("/")
    if any(part == ".." or ":" in part for part in raw_parts):
        raise UnsafeArchive(f"path traversal or platform path in archive: {name!r}")
    parts = [part for part in raw_parts if part not in ("", ".")]
    return "/".join(parts)


def resolve_link(member_name: str, target: str, *, hardlink: bool) -> str:
    if not target or "\x00" in target or "\\" in target or target.startswith("/"):
        raise UnsafeArchive(f"unsafe link target: {target!r}")
    raw = target.split("/")
    if any(":" in part for part in raw):
        raise UnsafeArchive(f"platform path in link target: {target!r}")
    parts: list[str] = [] if hardlink else member_name.split("/")[:-1]
    for part in raw:
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                raise UnsafeArchive(f"link escapes extraction root: {target!r}")
            parts.pop()
        else:
            parts.append(part)
    return "/".join(parts)


def contained(root: Path, relative: str) -> Path:
    result = root.joinpath(*PurePosixPath(relative).parts)
    resolved = result.resolve(strict=False)
    if resolved != root and root not in resolved.parents:
        raise UnsafeArchive(f"path escapes extraction root: {relative!r}")
    return result


def safe_extract(archive_path: Path, destination: Path) -> None:
    root = destination.resolve()
    if not root.is_dir() or any(root.iterdir()):
        raise UnsafeArchive("destination must be an existing empty directory")

    with tarfile.open(archive_path, mode="r:*") as archive:
        members = archive.getmembers()
        if not members or len(members) > MAX_MEMBERS:
            raise UnsafeArchive("archive is empty or contains too many entries")

        records: list[tuple[tarfile.TarInfo, str, str | None]] = []
        kinds: dict[str, str] = {}
        regular_files: dict[str, int] = {}
        hardlinks: list[tuple[str, str]] = []
        symlink_paths: set[str] = set()
        unpacked = 0

        for member in members:
            name = member_path(member.name)
            if not name:
                if member.isdir():
                    continue
                raise UnsafeArchive("archive contains a non-directory root entry")
            if member.isdir():
                kind, link = "directory", None
            elif member.isreg():
                kind, link = "file", None
                if member.size < 0:
                    raise UnsafeArchive(f"negative file size: {name}")
                unpacked += member.size
                if unpacked > MAX_UNPACKED_BYTES:
                    raise UnsafeArchive("archive exceeds the 16 GiB expanded size limit")
                regular_files[name] = member.size
            elif member.issym():
                kind = "symlink"
                link = resolve_link(name, member.linkname, hardlink=False)
                symlink_paths.add(name)
            elif member.islnk():
                kind = "hardlink"
                link = resolve_link(name, member.linkname, hardlink=True)
                hardlinks.append((name, link))
            else:
                raise UnsafeArchive(f"unsupported special archive entry: {name}")

            previous = kinds.get(name)
            if previous is not None and not (previous == kind == "directory"):
                raise UnsafeArchive(f"duplicate or conflicting archive path: {name}")
            kinds[name] = kind
            records.append((member, name, link))

        # Hardlinks are copied into independent files below, so their expanded
        # bytes count against the output limit just like regular files. Resolve
        # them before creating anything in the destination.
        for name, target_name in hardlinks:
            if target_name not in regular_files:
                raise UnsafeArchive(f"hardlink does not target a regular archive file: {name}")
            unpacked += regular_files[target_name]
            if unpacked > MAX_UNPACKED_BYTES:
                raise UnsafeArchive("archive exceeds the 16 GiB expanded size limit")

        # Nothing may be written through a path which the archive makes a symlink.
        for _, name, _ in records:
            parts = name.split("/")
            if any("/".join(parts[:i]) in symlink_paths for i in range(1, len(parts))):
                raise UnsafeArchive(f"entry is nested below a symlink: {name}")

        directories: set[str] = set()
        for _, name, kind_link in records:
            if not name:
                continue
            parts = name.split("/")
            for i in range(1, len(parts)):
                directories.add("/".join(parts[:i]))
            if kinds.get(name) == "directory":
                directories.add(name)

        for relative in sorted(directories, key=lambda value: (value.count("/"), value)):
            contained(root, relative).mkdir(mode=0o755, parents=True, exist_ok=True)

        for member, name, _ in records:
            if kinds.get(name) != "file":
                continue
            output = contained(root, name)
            output.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            executable = bool(member.mode & 0o111)
            fd = os.open(output, flags, 0o755 if executable else 0o644)
            written = 0
            try:
                source = archive.extractfile(member)
                if source is None:
                    raise UnsafeArchive(f"could not read archive entry: {name}")
                with source, os.fdopen(fd, "wb", closefd=False) as target:
                    while written < member.size:
                        block = source.read(min(COPY_CHUNK, member.size - written))
                        if not block:
                            raise UnsafeArchive(f"truncated archive entry: {name}")
                        target.write(block)
                        written += len(block)
                    if source.read(1):
                        raise UnsafeArchive(f"archive entry exceeds its declared size: {name}")
                    target.flush()
                    os.fsync(target.fileno())
            finally:
                os.close(fd)

        # Resolve links only after every regular file has been written, so a link
        # can never redirect extraction of a later member.
        for member, name, target_name in records:
            if kinds.get(name) == "hardlink":
                if target_name not in regular_files:
                    raise UnsafeArchive(f"hardlink does not target a regular archive file: {name}")
                source = contained(root, target_name)
                output = contained(root, name)
                output.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                shutil.copyfile(source, output)
            elif kinds.get(name) == "symlink":
                output = contained(root, name)
                output.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                if target_name is None:
                    raise UnsafeArchive(f"missing symbolic-link target: {name}")
                output_target = contained(root, target_name) if target_name else root
                # Store a relative link exactly as authored after checking its
                # normalized destination stays inside the private staging root.
                _ = output_target
                os.symlink(member.linkname, output)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {Path(sys.argv[0]).name} ARCHIVE.tar[.xz|.gz] EMPTY_DESTINATION", file=sys.stderr)
        return 2
    archive = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    try:
        safe_extract(archive, destination)
    except (OSError, tarfile.TarError, UnsafeArchive) as error:
        print(f"safe extraction refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
