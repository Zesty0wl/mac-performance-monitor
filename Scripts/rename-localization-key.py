#!/usr/bin/env python3
"""Rename a localization key without losing its translations.

English source text is used as the key, which keeps call sites readable and
makes untranslated strings fall back to correct English. The cost of that
choice is that editing English copy would normally orphan every translation
attached to the old wording: at ten languages, changing one word silently
throws away ten translations.

This closes that gap. It renames the key in the String Catalog, carrying every
language across untouched, and rewrites the matching literal in the Swift
sources so the call sites and the catalog stay in step.

    Scripts/rename-localization-key.py "Refresh interval" "Update interval"
    Scripts/rename-localization-key.py --catalog-only "Old" "New"
    Scripts/rename-localization-key.py --dry-run "Old" "New"

After renaming, check the translations still read correctly: a reworded English
string sometimes needs its translations revisited, which is a judgement the
tool cannot make. Their state is left as it was so you can decide.
"""
import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Localizations/Localizable.xcstrings")
SOURCES = os.path.join(ROOT, "Sources")


def swift_literal(text):
    """The Swift source form of a string literal's contents."""
    return text.replace("\\", "\\\\").replace('"', '\\"')


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("old")
    parser.add_argument("new")
    parser.add_argument("--catalog-only", action="store_true",
                        help="do not touch Swift sources")
    parser.add_argument("--dry-run", action="store_true",
                        help="report what would change and exit")
    args = parser.parse_args()

    with open(CATALOG, encoding="utf-8") as handle:
        catalog = json.load(handle)
    strings = catalog.get("strings", {})

    if args.old not in strings:
        print(f"error: {args.old!r} is not in the catalog", file=sys.stderr)
        return 1
    if args.new in strings:
        print(f"error: {args.new!r} is already in the catalog; merge by hand",
              file=sys.stderr)
        return 1

    entry = strings[args.old]
    langs = sorted(entry.get("localizations", {}))
    print(f"renaming {args.old!r} -> {args.new!r}")
    print(f"  carrying {len(langs)} language(s): {', '.join(langs)}")

    # The source-language value tracks the key when the two matched, which is
    # the normal case; a deliberately disambiguated key keeps its own wording.
    source = catalog.get("sourceLanguage", "en")
    unit = entry.get("localizations", {}).get(source, {}).get("stringUnit", {})
    if unit.get("value") == args.old:
        unit["value"] = args.new
        print(f"  {source} value tracked the key, so it becomes {args.new!r}")
    else:
        print(f"  {source} value is {unit.get('value')!r} and is left alone")

    edits = []
    if not args.catalog_only:
        needle = '"' + swift_literal(args.old) + '"'
        replacement = '"' + swift_literal(args.new) + '"'
        for directory, _, files in os.walk(SOURCES):
            for name in files:
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(directory, name)
                text = open(path, encoding="utf-8").read()
                if needle in text:
                    edits.append((path, text.count(needle),
                                  text.replace(needle, replacement)))
        total = sum(count for _, count, _ in edits)
        print(f"  {total} literal(s) in {len(edits)} Swift file(s)")
        for path, count, _ in edits:
            print(f"    {os.path.relpath(path, ROOT)} ({count})")
        if not edits:
            print("  note: no Swift literal matched. If this key is only reached")
            print("        through t() with a variable, that is expected.")

    if args.dry_run:
        print("dry run, nothing written")
        return 0

    strings[args.new] = strings.pop(args.old)
    with open(CATALOG, "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    for path, _, updated in edits:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(updated)

    print("done. Run Scripts/check-localization.py to confirm.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
