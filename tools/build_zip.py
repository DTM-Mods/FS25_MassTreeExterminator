"""Build dist/FS25_MassTreeExterminator.zip (modDesc.xml at the zip root) and run the GIANTS packaging checks:
at most 128 files, every Lua at most 0.5 MB, only known file types.

Usage: python tools/build_zip.py
Never copies anything into the game's mods folder; publishing goes through fs25_sftp_upload.py.
"""
import hashlib
import sys
import zipfile
from pathlib import Path

MOD_DIR = Path(__file__).resolve().parent.parent
OUT = MOD_DIR / "dist" / "FS25_MassTreeExterminator.zip"
EXCLUDE_DIRS = {"tools", "dist", ".git", ".github", ".vscode", "docs", "modhub", "screenshots"}
EXCLUDE_FILES = {".gitignore", ".gitattributes", "LICENSE"}
EXCLUDE_SUFFIXES = {".md", ".py", ".json", ".txt"}
KNOWN_SUFFIXES = {".xml", ".lua", ".i3d", ".shapes", ".dds", ".png", ".ogg", ".wav", ".gls", ".anim", ".cache", ".ies", ".pdf", ".l64", ".glsl"}


def files():
    for path in sorted(MOD_DIR.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(MOD_DIR)
        if rel.parts[0] in EXCLUDE_DIRS or rel.name in EXCLUDE_FILES or path.suffix.lower() in EXCLUDE_SUFFIXES:
            continue
        yield path, rel


def main():
    OUT.parent.mkdir(exist_ok=True)
    problems = []
    entries = list(files())
    if not (MOD_DIR / "modDesc.xml").is_file():
        sys.exit("no modDesc.xml")
    if len(entries) > 128:
        problems.append(f"{len(entries)} files, GIANTS allows 128")
    for path, rel in entries:
        if path.suffix.lower() == ".lua" and path.stat().st_size > 512 * 1024:
            problems.append(f"{rel} is {path.stat().st_size} bytes, Lua limit is 0.5 MB")
        if path.suffix.lower() not in KNOWN_SUFFIXES:
            problems.append(f"{rel}: unknown file type for GIANTS checks")
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as zf:
        for path, rel in entries:
            zf.write(path, rel.as_posix())
    sha = hashlib.sha256(OUT.read_bytes()).hexdigest()
    print(f"built {OUT} ({OUT.stat().st_size} bytes, {len(entries)} files) sha256 {sha}")
    for _, rel in entries:
        print("  ", rel.as_posix())
    for p in problems:
        print("WARNING:", p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
