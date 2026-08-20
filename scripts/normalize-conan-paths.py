#!/usr/bin/env python3
"""Remove Conan's per-build cache-directory suffixes from binary paths.

Conan package IDs are deterministic, but its local package directory names
include a package-revision suffix.  Some dependency objects retain those
paths in __FILE__/debug strings.  Keep the string length unchanged so this is
safe for already-linked ELF/ZIP member bytes.
"""

from __future__ import annotations

import re
import sys
import tempfile
import zipfile
from pathlib import Path


# Examples: /conan-package/p/b/fmt08196e275479f/...
# The final 13 hexadecimal characters are Conan's varying cache suffix.
_CACHE_SUFFIX = re.compile(
    rb"(?<=/conan-package/p/b/)([A-Za-z0-9_.-]*)([0-9a-f]{13})(?=/)"
)
_TMP_CACHE_SUFFIX = re.compile(
    rb"(?<=/tmp/tt-conan/p/b/)([A-Za-z0-9_.-]*)([0-9a-f]{13})(?=/)"
)


def normalize_data(data: bytes, path: Path) -> bytes:
    normalized = _CACHE_SUFFIX.sub(lambda match: match.group(1) + b"0" * 13, data)
    normalized = _TMP_CACHE_SUFFIX.sub(lambda match: match.group(1) + b"0" * 13, normalized)
    return normalized


def normalize_archive(path: Path) -> None:
    with zipfile.ZipFile(path, "r") as source:
        members = [(info, source.read(info)) for info in source.infolist()]
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as temp:
        temporary = Path(temp.name)
    try:
        with zipfile.ZipFile(temporary, "w", allowZip64=True) as target:
            for info, data in members:
                info.compress_type = info.compress_type
                target.writestr(info, normalize_data(data, path))
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def normalize(path: Path) -> None:
    if path.suffix == ".aar":
        normalize_archive(path)
        return
    data = path.read_bytes()
    normalized = normalize_data(data, path)
    if normalized != data:
        path.write_bytes(normalized)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: normalize-conan-paths.py FILE [...]")
    for name in sys.argv[1:]:
        normalize(Path(name))
