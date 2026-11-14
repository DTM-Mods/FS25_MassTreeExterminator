"""Checks that every text key the mod uses exists in both translation files, and that EN and DE have the same keys.

Usage: python tools/check_l10n.py
"""
import re
import sys
from pathlib import Path

MOD_DIR = Path(__file__).resolve().parent.parent


def keys(path):
    return set(re.findall(r'<text name="([^"]+)"', path.read_text(encoding="utf-8")))


def main():
    en = keys(MOD_DIR / "translations" / "translation_en.xml")
    de = keys(MOD_DIR / "translations" / "translation_de.xml")
    lua = "".join(p.read_text(encoding="utf-8") for p in (MOD_DIR / "scripts").rglob("*.lua"))
    xml = (MOD_DIR / "modDesc.xml").read_text(encoding="utf-8") + (MOD_DIR / "massTreeExterminatorTool.xml").read_text(encoding="utf-8")
    used = set(re.findall(r'"(mte_\w+)"', lua))
    used |= set(re.findall(r"\$l10n_(\w+)", xml))
    used |= {"input_" + a for a in re.findall(r'<action name="(\w+)"', xml)}
    problems = []
    for k in sorted(used - en):
        problems.append(f"missing in EN: {k}")
    for k in sorted(used - de):
        problems.append(f"missing in DE: {k}")
    for k in sorted(en ^ de):
        problems.append(f"only in one language: {k}")
    print(f"{len(used)} keys used, {len(en)} EN, {len(de)} DE")
    for p in problems:
        print("PROBLEM:", p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
