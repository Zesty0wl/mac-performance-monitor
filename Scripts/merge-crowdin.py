#!/usr/bin/env python3
r"""Fold the translations people made on Crowdin into main's String Catalog.

Crowdin imports the catalog from main, translations included, and exports the
whole file back to the `l10n_main` branch. Nearly everything it sends is
therefore an echo of main: a translation main already has, one main has since
replaced, or an English placeholder marked `new` for a string nobody has
translated yet. Its branch also never moves forward from the commit it was cut
from, so merging it as a pull request conflicts within a day.

This script compares the two catalogs entry by entry instead of merging files.
A Crowdin translation is taken only when all of these hold:

  * the key still exists on main (Crowdin's file can be older than main's);
  * the language is a target, not the source;
  * every string unit in it is marked `translated`;
  * main has never held it, at any commit since the history cut-off. Main
    holding it earlier means Crowdin is replaying a translation main has since
    changed, and main wins.

State is ignored when comparing, so a translation Crowdin marks `new` and main
marks `translated` counts as the same translation.

The catalog is written back with the exact formatting Xcode and Crowdin both
use, so an unchanged catalog stays byte-identical.

Usage:  Scripts/merge-crowdin.py [--crowdin-ref REF] [--since REF] [--dry-run]

Prints one line per merged translation and, last, the count. Exit status is 0
whether or not anything was merged.
"""

import argparse
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_PATH = "Localizations/Localizable.xcstrings"


def git(*args):
    return subprocess.run(
        ["git", "-C", ROOT, *args], check=True, capture_output=True, text=True
    ).stdout


def load_at(ref):
    return json.loads(git("show", f"{ref}:{CATALOG_PATH}"))


def dump(catalog):
    return json.dumps(catalog, indent=2, separators=(",", " : "), ensure_ascii=False)


def units(entry):
    """Every stringUnit in a localization, through variations and substitutions."""
    if isinstance(entry, dict):
        if "stringUnit" in entry:
            yield entry["stringUnit"]
        for value in entry.values():
            yield from units(value)


def fingerprint(entry):
    """A localization with its states removed, for comparison."""

    def strip(value):
        if isinstance(value, dict):
            return {k: strip(v) for k, v in value.items() if k != "state"}
        return value

    return json.dumps(strip(entry), sort_keys=True, ensure_ascii=False)


def history_fingerprints(since):
    """Every (key, language, fingerprint) main's catalog has held since `since`."""
    seen = set()
    commits = git("rev-list", f"{since}..HEAD", "--", CATALOG_PATH).split()
    for ref in [since, *commits]:
        try:
            catalog = load_at(ref)
        except subprocess.CalledProcessError:
            continue
        for key, string in catalog["strings"].items():
            for language, entry in string.get("localizations", {}).items():
                seen.add((key, language, fingerprint(entry)))
    return seen


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--crowdin-ref", default="origin/l10n_main")
    parser.add_argument(
        "--since",
        help="oldest main commit whose translations count as main's own "
        "(default: 120 days of history)",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    since = args.since or git(
        "rev-list", "-1", "--before=120 days ago", "HEAD"
    ).strip() or git("rev-list", "--max-parents=0", "HEAD").split()[0]

    path = os.path.join(ROOT, CATALOG_PATH)
    with open(path, encoding="utf-8") as handle:
        ours = json.load(handle)
    theirs = load_at(args.crowdin_ref)
    source = ours.get("sourceLanguage", "en")
    known = history_fingerprints(since)

    merged = []
    for key, string in theirs["strings"].items():
        target = ours["strings"].get(key)
        if target is None:
            continue
        for language, entry in string.get("localizations", {}).items():
            if language == source:
                continue
            states = [unit.get("state") for unit in units(entry)]
            if not states or any(state != "translated" for state in states):
                continue
            current = target.get("localizations", {}).get(language)
            if current is not None and fingerprint(current) == fingerprint(entry):
                continue
            if (key, language, fingerprint(entry)) in known:
                continue
            target.setdefault("localizations", {})[language] = entry
            merged.append((key, language))

    for key, language in merged:
        print(f"{language}\t{key}")
    print(f"{len(merged)} translation(s) from Crowdin")
    if merged and not args.dry_run:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(dump(ours))
    return 0


if __name__ == "__main__":
    sys.exit(main())
