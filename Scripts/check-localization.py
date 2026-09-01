#!/usr/bin/env python3
"""Audit the interface localisation tables.

Four classes of problem have all shipped at least once, and none of them is
visible in a diff:

  * A duplicate key. `.strings` is a plist, so the LAST definition silently wins.
    Two well-meaning translations of "Energy" left the Energy tab reading
    "consumption" instead of "battery".
  * A placeholder mismatch between a key and its translation. `String(format:)`
    reads whatever is on the stack when the count disagrees.
  * A string the UI shows that has no entry at all, which renders in English on
    an otherwise Chinese screen. That includes a string handed to a custom view
    whose parameter is typed `String` rather than `LocalizedStringKey`, which is
    never looked up however complete the table is.
  * A dead translation: the table has "%@ selected" but the source still writes
    `"\(count) selected"`, so the runtime key varies and never matches. The
    entry looks like coverage in the diff and shows English on screen.

Exit status is non-zero when any hard error is found. Missing translations are
reported but do not fail the run: English fallback is a deliberate feature, so
the count is a budget to drive down rather than a gate.

Usage:  Scripts/check-localization.py [--list-missing] [--list-stale]
"""

import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLES = {
    "zh-Hans": os.path.join(ROOT, "Sources/MacPerfMonitor/Resources/zh-Hans.lproj/Localizable.strings"),
    "en": os.path.join(ROOT, "Sources/MacPerfMonitor/Resources/en.lproj/Localizable.strings"),
}
SOURCES = os.path.join(ROOT, "Sources")

ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
SPEC = re.compile(r"%(?:(\d+)\$)?([@a-zA-Z%])")

# Left in English on purpose: proper nouns, units, and symbols that are the same
# word in both languages. A string here is never reported as missing.
KEEP_IN_ENGLISH = {
    "CPU", "GPU", "RAM", "SSD", "NVMe", "SMART", "APFS", "Dock", "Finder", "IOPS",
    "Rosetta", "Metal", "Wi-Fi", "Thunderbolt", "TCP", "UDP", "MAC", "PID", "UID",
    "SIGKILL", "CDHash", "TeamID", "SigningID", "PathPrefix", "SigningState",
    "WindowServer", "Swap", "Core ML", "Neural Engine", "USB", "PCI", "Bluetooth",
    "IPv4", "IPv6", "Mac", "macOS", "Apple", "P1", "P2", "P3",
    # Sizes and a sample Team ID: identical in both languages.
    "100 MB", "5 GB", "ABCDE12345",
    # Labels for the --uninstall command line output, never shown in the UI.
    "login item", "helper daemon",
}


def parse(path):
    """Return (entries, errors) where entries maps key -> [(line, value)]."""
    entries = defaultdict(list)
    errors = []
    if not os.path.exists(path):
        return entries, [f"{path}: missing"]
    for number, line in enumerate(open(path, encoding="utf-8"), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("/*") or stripped.startswith("*"):
            continue
        if stripped.startswith('"'):
            match = ENTRY.match(line.rstrip("\n"))
            if not match:
                errors.append(f"{path}:{number}: unparseable entry")
                continue
            entries[match.group(1)].append((number, match.group(2)))
    return entries, errors


def specifiers(text):
    """Conversion types in `text`, in argument order, ignoring escaped percents.

    A translation may write `%1$@ %2$@` where the key writes `%@ %@`: positional
    notation only makes the order explicit, and is exactly what a language needs
    when it has to reorder the arguments. So compare the conversions in argument
    order, not the notation. An unpositioned run is taken in the order it
    appears; a positioned one is sorted by its index.
    """
    found = [(m.group(1), m.group(2)) for m in SPEC.finditer(text) if m.group(2) != "%"]
    if any(index for index, _ in found):
        # Mixing the two forms in one string is undefined in CFString; report it
        # by leaving the mixed sequence in place so the comparison fails.
        if not all(index for index, _ in found):
            return ["mixed positional and unpositioned specifiers"]
        return [conversion for _, conversion in sorted(found, key=lambda f: int(f[0]))]
    return [conversion for _, conversion in found]


def unescape(text):
    text = re.sub(r"\\U([0-9A-Fa-f]{4})", lambda m: chr(int(m.group(1), 16)), text)
    return text.replace('\\"', '"').replace("\\n", "\n")


def swift_unescape(text):
    text = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), text)
    return text.replace('\\"', '"').replace("\\n", "\n")


# `"one " + "two"` written across source lines is a single table key at runtime.
# Splicing the halves back together before scanning keeps those keys off both the
# missing and the stale list.
CONCATENATION = re.compile(r'"\s*\+\s*"')
JOIN = "\x00"

# Call shapes whose first string literal is looked up in the table: SwiftUI views
# and modifiers that take a LocalizedStringKey, our own t(_:), and the explicit
# LocalizedStringKey(_:) conversion used where a call site builds the key.
LOOKUP_SITES = [
    re.compile(pattern)
    for pattern in [
        r'\bt\(\s*"((?:[^"\\\n]|\\.)*)"',
        r'\bLocalizedStringKey\(\s*"((?:[^"\\\n]|\\.)*)"',
        r'\bText\(\s*"((?:[^"\\\n]|\\.)*)"',
        r'\bLabel\(\s*"((?:[^"\\\n]|\\.)*)"',
        r'\bButton\(\s*"((?:[^"\\\n]|\\.)*)"',
        r'\bToggle\(\s*"((?:[^"\\\n]|\\.)*)"',
        r'\bPicker\(\s*"((?:[^"\\\n]|\\.)*)"',
        r'\bSection\(\s*"((?:[^"\\\n]|\\.)*)"',
        r'\bTextField\(\s*"((?:[^"\\\n]|\\.)*)"',
        r'\bMenu\(\s*"((?:[^"\\\n]|\\.)*)"',
        r'\bLabeledContent\(\s*"((?:[^"\\\n]|\\.)*)"',
        r'\.help\(\s*"((?:[^"\\\n]|\\.)*)"',
        r'\.navigationTitle\(\s*"((?:[^"\\\n]|\\.)*)"',
    ]
]


# Argument labels that carry UI copy in this codebase. These reach the screen
# through a struct (`MetricCardData(label:help:)`, `MetricExplanation(meaning:)`)
# or through a helper view, so they sit at no call shape the list above can see,
# and they are where the untranslated strings hid the longest.
KEYED_ARGUMENTS = re.compile(
    r"\b(label|help|meaning|calculation|subtitle|caption|headline|explanation|footnote"
    r'|placeholder|summary|hint)\s*:\s*"((?:[^"\\\n]|\\.)*)"'
)

COMMENT = re.compile(r"^[ \t]*(//|\*).*$", re.M)


def scan_sources():
    """Strings the UI looks up, as key -> first "file:line" that uses it.

    Scans whole files rather than single lines: swift-format routinely puts the
    literal on the line after `t(` or `Text(`, and concatenated halves are spliced
    back together first because the assembled string is the key at runtime.
    """
    found = {}
    for directory, _, files in os.walk(SOURCES):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            rel = os.path.relpath(path, ROOT)
            text = open(path, encoding="utf-8").read()
            # Blank out comments so a quoted example in a doc comment is not
            # mistaken for a lookup, keeping offsets (and so line numbers) intact.
            text = COMMENT.sub(lambda m: " " * len(m.group(0)), text)
            # Blank the `" + "` with a sentinel rather than spaces: the halves
            # then read as one literal, and stripping the sentinel out of the
            # capture rebuilds the key without inventing whitespace.
            text = CONCATENATION.sub(lambda m: JOIN * len(m.group(0)), text)
            matches = [(m, 1) for p in LOOKUP_SITES for m in p.finditer(text)]
            matches += [(m, 2) for m in KEYED_ARGUMENTS.finditer(text)]
            for match, group in matches:
                raw = match.group(group).replace(JOIN, "")
                if not raw or "\\(" in raw:
                    continue
                key = swift_unescape(raw)
                if not re.search(r"[A-Za-z]", key):
                    continue
                # A bare lowerCamelCase word or a dotted token is an identifier,
                # not copy: `label: "cpu"`, `help: "com.example.thing"`.
                if re.fullmatch(r"[a-z][A-Za-z0-9]*", key) or re.fullmatch(
                    r"[\w-]+(\.[\w-]+)+", key
                ):
                    continue
                number = text.count("\n", 0, match.start()) + 1
                found.setdefault(key, f"{rel}:{number}")
    return found


def scan_all_literals():
    """Every string literal in the source, for the stale-entry check."""
    literal = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
    found = set()
    for directory, _, files in os.walk(SOURCES):
        for name in files:
            if not name.endswith(".swift"):
                continue
            text = open(os.path.join(directory, name), encoding="utf-8").read()
            for match in literal.finditer(CONCATENATION.sub("", text)):
                found.add(swift_unescape(match.group(1)))
    return found


# A key such as "%@ selected" is dead if the source still writes
# `"\(count) selected"`: the runtime key varies, so the lookup never hits and the
# translation is never seen. This turns the key back into a pattern and looks for
# the interpolated form.
# Calls whose argument is a LocalizedStringKey. A literal *with interpolation*
# written here is not a bug: SwiftUI builds the key by replacing each
# interpolation with its format specifier, so `Text("\(count) open")` looks up
# "%lld open" and finds it. The same literal assigned to a String first, or
# handed to a String parameter, renders verbatim and never reaches the table.
# Whether a literal reaches the table depends on the type of the expression it
# sits in, and that is not knowable from the text: `return "..."` may return a
# LocalizedStringKey, an argument may bind to one, a ternary of literals resolves
# to one. Guessing produced more false alarms than findings, so this reports only
# the one shape that was verified against the compiler to be broken.
#
# Measured with a Probe type carrying SwiftUI's own overload pair (the
# StringProtocol one marked @_disfavoredOverload):
#
#   Probe("plain")                  -> LocalizedStringKey   looked up
#   Probe(c ? "one" : "many")       -> LocalizedStringKey   looked up
#   Probe(c ? "one" : "\(n) many")  -> LocalizedStringKey   looked up
#   Probe("\(n) entries")           -> LocalizedStringKey   looked up
#   Probe(c ? "one" : someString)   -> String               NOT looked up
#
# Only the last one is reported: one branch being a String variable types the
# whole ternary as String, so every literal in it renders verbatim.
MIXED_TERNARY = re.compile(
    r'\?\s*"(?:[^"\\]|\\.)*"\s*:\s*[A-Za-z_][\w.]*(?![\w.]*\s*\()'
    r'|\?\s*[A-Za-z_][\w.]*\s*:\s*"(?:[^"\\]|\\.)*"'
)


def interpolation_sites(key, sources):
    """Sites where this key's literal sits in a ternary typed as String.

    Returns (live, dead) to keep the caller unchanged: `live` is every other
    occurrence, which this no longer tries to judge, and `dead` is the shape
    above, which is provably not looked up.
    """
    parts = re.split(r"%(?:\d+\$)?(?:@|lld|ld|d|lf|f)", key)
    if len(parts) == 1:
        return [], []
    pattern = re.compile('"' + r"\\\([^)]*\)".join(re.escape(part) for part in parts) + '"')
    live, dead = [], []
    for path, text in sources.items():
        for match in pattern.finditer(text):
            where = f"{path}:{text.count(chr(10), 0, match.start()) + 1}"
            window = text[max(0, match.start() - 80):match.end() + 80]
            (dead if MIXED_TERNARY.search(window) else live).append(where)
    return live, dead


def read_sources():
    """Every Swift file's text, keyed by repo-relative path."""
    texts = {}
    for directory, _, files in os.walk(SOURCES):
        for name in files:
            if name.endswith(".swift"):
                path = os.path.join(directory, name)
                texts[os.path.relpath(path, ROOT)] = open(path, encoding="utf-8").read()
    return texts


def main():
    errors = []
    warnings = []

    tables = {}
    for language, path in TABLES.items():
        entries, parse_errors = parse(path)
        errors.extend(parse_errors)
        tables[language] = entries

        for key, occurrences in entries.items():
            if len(occurrences) > 1:
                lines = ", ".join(str(n) for n, _ in occurrences)
                values = {v for _, v in occurrences}
                detail = "same value" if len(values) == 1 else "DIFFERENT values"
                errors.append(
                    f"{os.path.relpath(path, ROOT)}: duplicate key {key!r} "
                    f"on lines {lines} ({detail}); the last one silently wins"
                )
            for number, value in occurrences:
                if specifiers(unescape(key)) != specifiers(unescape(value)):
                    errors.append(
                        f"{os.path.relpath(path, ROOT)}:{number}: placeholders differ "
                        f"between key and translation for {key!r}"
                    )

    used = scan_sources()
    literals = scan_all_literals()
    zh = tables["zh-Hans"]
    zh_keys = {unescape(k) for k in zh}

    missing = {
        key: where
        for key, where in used.items()
        if key not in zh_keys and key not in KEEP_IN_ENGLISH
    }
    # A key is only stale when it appears NOWHERE in the source as a literal.
    # Plenty of keys are reached through a runtime String (an enum's `label`, a
    # panel title threaded through a helper), so `used` alone would condemn them.
    stale = sorted(key for key in zh_keys if key not in used and key not in literals)

    # A key written as an interpolated literal inside a LocalizedStringKey call
    # is in use: SwiftUI builds exactly this key from it. Those are neither
    # stale nor dead, and they are the bulk of what a literal-only scan misses.
    texts = read_sources()
    dead = {}
    live_interpolated = set()
    for key in stale:
        live, dead_sites = interpolation_sites(key, texts)
        if live:
            live_interpolated.add(key)
        elif dead_sites:
            dead[key] = dead_sites[0]
    stale = [key for key in stale if key not in live_interpolated]

    print(f"zh-Hans entries:      {len(zh)}")
    print(f"lookups in Sources:   {len(used)}")
    print(f"missing translation:  {len(missing)}")
    print(f"unused table entries: {len(stale)}")

    if "--list-missing" in sys.argv:
        print()
        for key, where in sorted(missing.items(), key=lambda item: item[1]):
            print(f"  {where}\t{key}")
    if "--list-stale" in sys.argv:
        print()
        for key in stale:
            print(f"  {key}")

    if dead:
        print()
        print(
            f"dead translations ({len(dead)}): the source builds the string before "
            "anything can look it up"
        )
        for key, where in sorted(dead.items(), key=lambda item: item[1]):
            print(f"  {where}\t{key[:80]}")

    if warnings:
        print()
        for warning in warnings:
            print(f"warning: {warning}")
    if errors:
        print()
        for error in errors:
            print(f"error: {error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
