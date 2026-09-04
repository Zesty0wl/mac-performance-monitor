# Contributing to MacPerfMonitor

Thank you for your interest in improving MacPerfMonitor. This project aims to be a
credible, auditable, no-telemetry macOS system tool, and contributions of all
sizes are welcome.

## Building and testing

MacPerfMonitor builds with the Swift toolchain and needs no Apple Developer account or
signing identity.

```sh
swift build          # compile everything
swift test           # run the full test suite
Scripts/run.sh       # build, bundle, ad-hoc sign, and launch the app
```

Use `Scripts/run.sh --release` to match the shipping build. Note that
`swift build` alone does not refresh the `build/MacPerfMonitor.app` bundle; always use
`Scripts/run.sh` when you want to launch your latest changes.

**Requirements:** macOS 15 (Sequoia) or later and a Swift 6 toolchain (Xcode 16 or a
Swift.org toolchain).

## Linting and formatting

The project uses the Swift toolchain's built-in formatter, configured by
[.swift-format](.swift-format). Continuous integration runs it in strict mode,
so please format before opening a pull request:

```sh
# Check for violations (this is what CI runs)
swift format lint --strict --recursive Sources Tests Package.swift

# Apply formatting in place
swift format --in-place --recursive Sources Tests Package.swift
```

Formatting is the one thing CI has ever failed on here, so there is a hook that
checks staged Swift files before a commit is made. Turn it on once per clone:

```sh
git config core.hooksPath .githooks
```

`Scripts/install.sh` runs the same check before it builds, so a release can
never be cut from code CI will reject. Set `SKIP_LINT=1` to bypass it for a
local-only build.

CI must stay green with no secrets and no code signing, so any fork gets a
working build on the first try.

## Coding conventions

- **Swift 6 toolchain, Swift 5 language mode.** The package pins
  `swiftLanguageModes: [.v5]` deliberately; keep new code compatible with it.
- **Keep `MacPerfMonitorCore` free of SwiftUI.** The data layer (readers, models,
  sampling, persistence, analysis) must build and be testable headlessly. Put
  pure analysis in `Analysis/` and database-querying code in `Persistence/`. The
  app target depends only on `MacPerfMonitorCore`.
- **Test the data layer.** New analysis or persistence logic should come with
  tests in `MacPerfMonitorCoreTests`. UI is verified manually.
- **Logging.** Use the `AppLog` categories. Any log line you intend to rely on
  as evidence after the fact must be `.notice` (persisted), not `.info` (which
  ages out of the in-memory buffer).
- **SPDX headers.** New source files should start with a single-line identifier:
  `// SPDX-License-Identifier: MIT`.

## Writing style for docs and copy

User-facing copy and Markdown documentation in this repository **avoid the em
dash**. Use a colon, a pair of commas, parentheses, or two separate sentences
instead. This keeps the prose plain and consistent. The rule applies to product
copy and docs; ordinary code comments are exempt.

## Translations

Every language lives in one String Catalog, `Localizations/Localizable.xcstrings`.
Adding a language is one file plus a single Swift `case` for the Settings picker,
and partial translations are welcome: anything untranslated falls back to English.

See **[TRANSLATING.md](TRANSLATING.md)** for the full guide, including how
plurals work (your language's own CLDR categories, not English's two), how to
keep format specifiers correct, and how to find hardcoded English with
`Scripts/pseudolocalize.sh`.

`Scripts/check-localization.py` runs in CI and is the same check you can run
locally. It fails the build on a missing source value, a missing translation in
a language declared complete, and any translation whose format specifiers do not
match its key.

Compiled `.lproj` directories are build output produced by `Scripts/bundle.sh`.
They are not in the repository and must not be committed.

### Changing English copy

English source text doubles as the localization key, which keeps call sites
readable and makes anything untranslated fall back to correct English. The cost
is that editing a string would normally orphan every translation attached to the
old wording. Use the rename tool instead of editing the literal by hand:

```sh
Scripts/rename-localization-key.py "Refresh interval" "Update interval"
```

It renames the key in the catalog, carries every language across untouched, and
rewrites the matching Swift literals so the sources and the catalog stay in
step. Pass `--dry-run` first to see what it would touch. A reworded string
sometimes needs its translations revisited, which the tool cannot judge, so it
leaves their state alone for you to decide.

### Strings that need a key of their own

Some keys are longer than the text they display, because English reuses one word
where another language needs two. `"Low Power Mode on"` displays "On". Reach for
this whenever a short generic word (`Free`, `Other`, `System`, `Scan`) would
otherwise have to carry two different meanings, and give the catalog an explicit
English value. `check-localization.py` fails the build if a key has no
source-language value, which is what stops the key itself leaking to the screen.

### Crowdin

Translators can work at https://crowdin.com/project/mac-performance-monitor instead of
editing the catalog. `crowdin.yml` configures the integration: Crowdin reads
and writes the catalog directly and opens a pull request titled "Translations
from Crowdin" on the `l10n_main` branch, about once an hour when something has
changed. It never commits to the default branch. Two lines there are
load-bearing. `multilingual: true` stops Crowdin splitting the catalog into one
file per language, and `append_commit_message: false` removes the CI-skip tag
Crowdin adds to commits by default, so CI runs on its pull requests.

Maintainer notes for the Crowdin project settings: the GitHub integration has
"Always import new translations from the repository" and "Allow target
translation to match source" switched on. The second matters because Crowdin
otherwise skips translations identical to the English (CPU, USB, Wi-Fi and the
like) and reports the language as incomplete. When someone asks for a new
language, add it as a target language in the Crowdin project, add its `case` to
`AppLanguage` in `Sources/MacPerfMonitor/Settings/AppLanguageManager.swift`,
and once it is complete add it to `COMPLETE_LANGUAGES` in
`Scripts/check-localization.py`. A language generated by an AI model also goes
into `AppLanguage.machineTranslated` with its strings in state `needs_review`,
which drives the Settings notice; take it out again once a native speaker has
reviewed the language.

Crowdin's pull request conflicts whenever a commit on `main` touches the
catalog while that pull request is open, because both sides rewrite the same
regions of one JSON file. Resolve it by taking Crowdin's copy whole: check out
`l10n_main`, merge `main` into it, keep `--ours` for
`Localizations/Localizable.xcstrings`, push, and merge the pull request once CI
passes. Crowdin holds the translations, so its file is the one to keep. Before
merging, confirm the diff against `main` is only what Crowdin is entitled to
change: the same set of keys, English and any language nobody edited untouched,
and per-string differences limited to the `state` field and whitespace.

## Submitting changes

1. Fork the repository and create a topic branch.
2. Make your change, with tests where the data layer is involved.
3. Run `swift test` and `swift format lint --strict` and make sure both pass.
4. Update [CHANGELOG.md](CHANGELOG.md) under "Unreleased" if the change is
   user-visible.
5. Open a pull request using the template, describing what changed and why, and
   how you verified it.

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
