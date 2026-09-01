#!/usr/bin/env python3
"""Report UI strings the app looks up but the String Catalog does not carry.

check-localization.py scans source text for lookups, which finds the strings
passed to t(). It cannot see what SwiftUI does to an interpolated literal: the
compiler decides the key, and it is not always what a human would write.
`Text("\\(count) cores")` looks up `%lld cores`, not `%@ cores`, so a
translation filed under the second form is never found and the string silently
renders in English forever.

This asks the compiler instead. It builds with -emit-localized-strings, which
is the same extraction Xcode uses, and compares the keys the compiler actually
emits against the catalog.

    Scripts/check-string-coverage.py
    Scripts/check-string-coverage.py --all   # include punctuation-only keys

Keys with no letters in them (" / ", "%@ · %@") are composition rather than
copy and are hidden by default.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Localizations/Localizable.xcstrings")


def compiler_keys(destination):
    """Every localization key the Swift compiler emits, key -> source file."""
    print("building with -emit-localized-strings ...", file=sys.stderr)
    result = subprocess.run(
        ["swift", "build",
         "-Xswiftc", "-emit-localized-strings",
         "-Xswiftc", "-emit-localized-strings-path",
         "-Xswiftc", destination],
        cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr[-2000:], file=sys.stderr)
        raise SystemExit("build failed")
    found = {}
    for path in glob.glob(os.path.join(destination, "*.stringsdata")):
        raw = subprocess.run(["plutil", "-convert", "json", "-o", "-", path],
                             capture_output=True).stdout
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            continue
        origin = os.path.basename(path).replace(".stringsdata", "")
        for table in data.get("tables", {}).values():
            for entry in table:
                if isinstance(entry, dict) and "key" in entry:
                    found.setdefault(entry["key"], origin)
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--all", action="store_true",
                        help="include keys with no letters in them")
    args = parser.parse_args()

    with open(CATALOG, encoding="utf-8") as handle:
        catalog = set(json.load(handle)["strings"])

    with tempfile.TemporaryDirectory() as destination:
        emitted = compiler_keys(destination)

    missing = {k: v for k, v in emitted.items() if k not in catalog}
    if not args.all:
        missing = {k: v for k, v in missing.items() if re.search(r"[A-Za-z]{3}", k)}

    print(f"keys the compiler emits: {len(emitted)}")
    print(f"keys in the catalog:     {len(catalog)}")
    print(f"not carried:             {len(missing)}")
    if missing:
        print("\nThese render in English in every language:")
        for key in sorted(missing, key=lambda k: (missing[k], k)):
            print(f"  [{missing[key]}] {key!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
