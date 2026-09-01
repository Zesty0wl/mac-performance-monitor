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

> **Adding a new language? Please hold for now.** The localization system is
> being restructured onto Apple String Catalogs (`.xcstrings`) with semantic
> keys, which changes how translations are authored and will re-key the existing
> tables. Existing translations carry across automatically, but a new language
> started today would be re-keyed underneath you. Open an issue to register
> interest and we will ping you the moment the new workflow lands. Corrections
> and fixes to the existing English and Simplified Chinese are welcome as normal.


MacPerfMonitor is localized by its community. English strings live in
`Sources/MacPerfMonitor/Resources/en.lproj/Localizable.strings` with one folder per
language beside it. Simplified Chinese arrived as a community pull request: thank you!

To add a language:

1. Copy `en.lproj` to your locale's folder, for example `fr.lproj`, and translate the
   right-hand values. The left-hand side stays in English; it is the lookup key.
2. Add a case to `AppLanguage` in
   `Sources/MacPerfMonitor/Settings/AppLanguageManager.swift` so the language appears
   in the Settings language picker.
3. Build with `Scripts/run.sh`, switch the language in Settings, and click through the
   app looking for untranslated or overflowing text.
4. Open a pull request. Partial translations are fine to start with; any key missing
   from your file falls back to English.

Keep format specifiers (`%@`, `%lld`) exactly as they appear in the English value and
in the same order, unless your language needs reordering (then use `%1$@`, `%2$@`).

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
