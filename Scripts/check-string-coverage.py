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
    Scripts/check-string-coverage.py --all           # list the allowlist too
    Scripts/check-string-coverage.py --stringsdata D # reuse an earlier build

Exit status is non-zero when the compiler emits a key the catalog does not
carry and the allowlist below does not excuse, so CI fails on a string that
would ship untranslated. --stringsdata skips the build and reads the
.stringsdata files an earlier build already wrote, which is how CI runs it.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Localizations/Localizable.xcstrings")

# Keys that are emitted but are deliberately not in the catalog, because no
# language would render them differently. Anything not listed here has to be
# carried, so a new string cannot ship untranslated by accident. Keep the
# reason with the entry: an allowlist nobody can audit rots.
NOT_TRANSLATED = {
    # Composition: placeholders, separators and glyphs, with no word in them.
    " · ", " — %@", "%@ %@ (%@)", "%@ (%@)", "%@ / %@", "%@ · %@", "%@ → %@",
    "%@: %@", "%lld", "%lld %@", "%lld / %lld", "%lld/%lld", "%lld%%", "%u",
    "%u%%", "×%lld", "+%@", "--", ". ", "·", "—", "•", "›", "",
    # Units and identifiers that read the same in every language. PID, MAC and
    # the protocol names are the same list check-localization.py keeps in
    # KEEP_IN_ENGLISH.
    "%lld ms", "± %lld ms", "80%", "fd %d · %@", "PID %d", "PID %d · UID %u",
    "%@ · PID %d", "PID %d · %@%@",
    "MTU", "MAC", "DNS", "SMB", "mDNS", "IPv4", "RAM",
    # Sample values shown as a text field's placeholder, not as copy.
    "1", "1024", "192.168.1.1", "192.168.1.254", "ABCDE12345",
    # Swift Charts series and axis identifiers: named for the code that reads
    # them back, never drawn on screen.
    "t", "u", "c", "Segment", "Value", "Full",
}


def read_stringsdata(destination):
    """Every localization key in a directory of .stringsdata, key -> module."""
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
    return read_stringsdata(destination)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--all", action="store_true",
                        help="also list the keys the allowlist excuses")
    parser.add_argument("--stringsdata", metavar="DIR",
                        help="read .stringsdata from DIR instead of building")
    args = parser.parse_args()

    with open(CATALOG, encoding="utf-8") as handle:
        catalog = set(json.load(handle)["strings"])

    if args.stringsdata:
        emitted = read_stringsdata(args.stringsdata)
        if not emitted:
            print(f"error: no .stringsdata files in {args.stringsdata}", file=sys.stderr)
            return 1
    else:
        with tempfile.TemporaryDirectory() as destination:
            emitted = compiler_keys(destination)

    uncarried = {k: v for k, v in emitted.items() if k not in catalog}
    missing = {k: v for k, v in uncarried.items() if k not in NOT_TRANSLATED}
    excused = {k: v for k, v in uncarried.items() if k in NOT_TRANSLATED}
    # An allowlist entry the compiler no longer emits is a leftover: the call
    # site it excused is gone, so drop it rather than let the list rot.
    unused = sorted(NOT_TRANSLATED - set(emitted))

    print(f"keys the compiler emits: {len(emitted)}")
    print(f"keys in the catalog:     {len(catalog)}")
    print(f"allowed to stay English: {len(excused)}")
    print(f"not carried:             {len(missing)}")
    if missing:
        print("\nThese render in English in every language. Add them to "
              "Localizations/Localizable.xcstrings, or to NOT_TRANSLATED in "
              "this script when no language would render them differently:")
        for key in sorted(missing, key=lambda k: (missing[k], k)):
            print(f"  [{missing[key]}] {key!r}")
    if args.all and excused:
        print("\nAllowed to stay English:")
        for key in sorted(excused, key=lambda k: (excused[k], k)):
            print(f"  [{excused[key]}] {key!r}")
    if unused:
        print("\nNOT_TRANSLATED entries the compiler no longer emits:")
        for key in unused:
            print(f"  {key!r}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
