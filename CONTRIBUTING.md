# Contributing to Mac Performance Monitor

Mac Performance Monitor is a native macOS tool with local performance history
and no usage telemetry. Contributions to code, tests, docs, and translations
are welcome. Target `main` for new work; it contains the 2.0 release source.

## Building and testing

Building and running the tests needs no Apple Developer account or signing key.
Use Apple silicon and macOS 15 or later. The current preview build uses Xcode 27
for App Intents metadata and the local-inference worker. Install its GPU compiler
with `xcodebuild -downloadComponent MetalToolchain`. Apple's `xcstringstool`
compiles the String Catalog. Model weights are not needed for ordinary tests.

```sh
swift build
swift test
Scripts/run.sh --adhoc
```

The last command bundles and launches `build/Mac Performance Monitor.app`.
`swift build` alone does not refresh that bundle. Add `--release` to test an
optimized build. This does not make it a signed, notarized distribution build.

Without `--adhoc`, the script uses a signing identity from the keychain when
one is available. `--developer-id` makes a real identity mandatory. Ad-hoc
builds cannot use the privileged helper; use compatible app/helper signatures
for full-coverage and performance tests.

The test suite has three targets:

- `MacPerfMonitorCoreTests`: readers, sampling, analysis, storage, and retention.

- `MacPerfMonitorIPCTests`: the helper contract and connection behavior.

- `MacPerfMonitorTests`: native chart rendering, window and menu layout,
  Explorer navigation, alert evidence, and export behavior.

Native tests need a macOS graphical session. Some checks use synthetic fixtures;
others need a running Mac or explicit opt-in data. A passing fixture does not
replace a manual check of the signed app. See the commands in
[Explorer](docs/explorer-design.md) and [Adaptive alerts](docs/adaptive-alerts.md)
for native previews and read-only history replay.

For Ask's ordinary tests, run:

```sh
swift test --filter 'AskPreviewTests|AskReportTests'
```

Apple tests need a ready Apple Intelligence model, but no Qwen download.
They cover routing, answers, and database tools. The smoke test also checks
memory pressure, disk activity, and missing network data. To run them:

```sh
MACPERF_TEST_FOUNDATION_MODELS=1 swift test --filter 'AskPreviewTests/testRealApple|AskPreviewTests/testRealOnDeviceRouting'
```

Qwen tests need an opt-in flag, a test model folder, and a built worker:

```sh
MACPERF_TEST_QWEN=1 \
MACPERF_TEST_QWEN_DIRECTORY=/path/to/test-model \
MACPERF_TEST_INFERENCE_BINARY=/path/to/MacPerfMonitorInference \
swift test --filter AskPreviewTests/testRealQwen
```

The download test fetches about 2.3 GB if the test folder has no verified model.
Use a Mac with at least 16 GiB RAM and normal memory pressure. Run real models
separately when memory is tight. Do not bypass the pressure gate to pass a test.

To try any downloaded local model without fetching weights, use its backend ID:

```sh
MACPERF_TEST_LOCAL_BACKEND=qwen35 \
MACPERF_TEST_LOCAL_MODEL_DIRECTORY=/path/to/downloaded-model \
MACPERF_TEST_INFERENCE_BINARY=/path/to/MacPerfMonitorInference \
swift test --filter AskPreviewTests/testRealSelectedLocalModelWhenExplicitlyEnabled
```

The IDs are `qwen`, `qwen35`, and `deepAnalyze`. Download the selected model from
Ask settings first, or supply a separate folder with the exact pinned files.
The test uses synthetic history, not your recorded activity. It checks tool use,
citations, output limits, and reported memory. Qwen3.5 and DeepAnalyze remain
experimental; a passing trial is not a broad accuracy score. Run one model at a time.
The GGUF memory metric is peak resident memory; the MLX metric is peak allocations.
Do not compare those values as though they measured the same thing.

The real-model investigation tests build a temporary SQLite history with known
CPU activity. They check that the model requests history and process evidence,
not just a current snapshot. Ordinary tests exercise the child-process protocol
with a lightweight fixture, including cancellation and forged citations.
Inspect the actual diagnosis as well as test status: valid citations alone do
not show that a model interpreted them correctly.

To replay existing history with Apple, pass its database path:

```sh
MACPERF_TEST_FOUNDATION_MODELS=1 \
MACPERF_TEST_ASK_DATABASE="$HOME/Library/Application Support/MacPerformanceMonitor/macperfmonitor.sqlite" \
swift test --filter AskPreviewTests/testRealAppleReadOnlyLocalHistoryWhenExplicitlyEnabled
```

For Qwen, use the Qwen flags above and its replay test:

```text
AskPreviewTests/testRealQwenReadOnlyLocalHistoryWhenExplicitlyEnabled
```

Both tests open the database read-only and use fresh reports without recording.
They omit private evidence and answers from their output. Neither downloads a
model. For Qwen, use a verified model folder and the worker you want to test.

To repeat Qwen's final-answer step on a fixed interval, use the same flags with
an ISO 8601 date that includes a time zone:

```text
MACPERF_TEST_ASK_DATE=2026-09-18T09:33:10+01:00
AskPreviewTests/testRealQwenPinnedAnswerWhenExplicitlyEnabled
```

This test reads the same recorded interval on each run. It does not take live
samples or write to history.

## Linting and formatting

For the ANE accounting preview, run the focused reader, history, and display tests:

```sh
swift test --filter 'GPUAttributionTests|GPUHistoryTests|MetricCardPresentationTests'
```

The live sampler test needs macOS 27 and a ready Apple Intelligence model:

```sh
MACPERF_TEST_FOUNDATION_MODELS=1 swift test --filter GPUAttributionTests/testProductionSamplerReadsANE
```

Set `MACPERF_ANE_ARTIFACTS` to an output folder to capture the native ANE preview
windows in the display test. This uses macOS screen capture and needs its usual
permission. Without the variable, tests use view rendering only. No test writes
to the user's history. See [ANE activity](docs/gpu-tab-design.md#ane-activity-preview-18-september-2026)
for units, availability, and coverage limits.

For ANE power, add the helper tests. They use an anonymous XPC listener and
short-lived fixture processes, so the ordinary suite needs no root privileges:

```sh
swift test --filter 'HelperRoundTripTests|GPUAttributionTests|GPUHistoryTests|MetricCardPresentationTests'
```

To replay an existing native plist capture without starting a root sampler:

```sh
MACPERF_TEST_ANE_CAPTURE=/path/to/powermetrics-capture \
swift test --filter HelperRoundTripTests/testRealASITopCaptureWhenExplicitlyProvided
```

The capture must include nonzero ANE energy and use powermetrics' NUL-separated
plist format. The test prints only sample counts and peak watts. For the live
signed-app check, install both updated binaries and enable Full Coverage. Check
that ANE watts appear during inference and become unavailable when coverage is
off, while ANE Time keeps working. No asitop process should be required.

The project uses the Swift toolchain's built-in formatter, configured by
[.swift-format](.swift-format). Continuous integration runs it in strict mode,
so please format before opening a pull request:

```sh
# Check for violations (this is what CI runs)
swift format lint --strict --recursive Sources Tests Package.swift

# Apply formatting in place
swift format format --in-place --recursive Sources Tests Package.swift
```

A hook checks staged Swift files before a commit. Turn it on once per clone:

```sh
git config core.hooksPath .githooks
```

`Scripts/install.sh` runs the same lint check before building. It also changes
the build number, signs and notarizes the app, and installs it in Applications.
It is a maintainer test-build command, not a routine contributor build step.

CI must stay green with no secrets and no code signing, so any fork gets a
working build on the first try.

## Coding conventions

- **Swift 6 toolchain, Swift 5 language mode.** The package pins
  `swiftLanguageModes: [.v5]` deliberately; keep new code compatible with it.
- **Keep `MacPerfMonitorCore` free of SwiftUI.** The data layer (readers, models,
  sampling, persistence, analysis) must build and be testable headlessly. Put
  pure analysis in `Analysis/` and database-querying code in `Persistence/`.
  App-only UI, IPC, and Sparkle integration belong outside Core.
- **Test the data layer.** New analysis or persistence logic should come with
  tests in `MacPerfMonitorCoreTests`. Add native tests for UI behavior where
  practical, then inspect the result in the app.
- **Keep historical data honest.** Preserve timestamps, source intervals,
  unknown readings, and stored bounds. Follow the
  [chart standard](docs/dashboard-chart-standard.md) for Dashboard and Explorer.
- **Logging.** Use the `AppLog` categories. Any log line you intend to rely on
  as evidence after the fact must be `.notice` (persisted), not `.info` (which
  ages out of the in-memory buffer).
- **SPDX headers.** New source files should start with a single-line identifier:
  `// SPDX-License-Identifier: MIT`.

## Writing style for docs and copy

Do not use em or en dashes in prose, UI copy, code comments, commit messages,
or PR descriptions. Use commas, colons, parentheses, or separate sentences.
Regular hyphens in compound words are fine. See [CLAUDE.md](CLAUDE.md).

## Translations

Every language lives in one String Catalog, `Localizations/Localizable.xcstrings`.
Adding a language also needs an entry in the Settings language picker. Partial
new languages are welcome. English, Simplified Chinese, German, and French must
keep full key coverage, even when individual translations await native review.

See **[TRANSLATING.md](TRANSLATING.md)** for the full guide, including how
plurals work (your language's own CLDR categories, not English's two), how to
keep format specifiers correct, and how to find hardcoded English with
`Scripts/pseudolocalize.sh`.

`Scripts/check-localization.py` runs in CI and is the same check you can run
locally. It fails the build on a missing source value, a missing translation in
a language declared complete, and any translation whose format specifiers do not
match its key.

`Scripts/check-string-coverage.py` runs in CI too and answers a question source
text cannot. It uses the compiler to check keys that source scanning misses.
For example, `Text("\(count) inside")` looks up `%lld inside`, not `%@ inside`.
Add missing UI copy to the catalog. Only language-independent strings belong
in the script's `NOT_TRANSLATED` allowlist. Keep a reason beside each such entry.

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
where another language needs two. `"Low Power Mode on"` displays "On". Use distinct
keys when a short word has different meanings in different views. Give each
key an explicit English value. The source-language check prevents internal key
names from appearing in the interface.

### Crowdin

Translators can use [Crowdin](https://crowdin.com/project/mac-performance-monitor).
The settings in `crowdin.yml` keep translations in one catalog. Crowdin opens
PRs from `l10n_main`, rather than writing to the default branch.
Keep `multilingual: true` so it does not split the catalog by language.
Keep `append_commit_message: false` so its commits do not skip CI.

Allow imports from the repository and translations that match the source.
The latter matters for terms such as CPU and USB. Otherwise Crowdin may report
those entries as missing. Add new languages to both Crowdin and `AppLanguage`.
Add a language to `COMPLETE_LANGUAGES` only when it has full key coverage.
Keep AI-generated languages in `AppLanguage.machineTranslated` until native
review is complete. That list controls the notice in Settings.

Resolve catalog conflicts by key and language. Keep current source keys and
English values from the target branch, and preserve reviewed translations from
Crowdin. Do not take either catalog wholesale: that can discard new Explorer
and alert strings or overwrite a translator's corrections. Check the diff,
run both coverage checks, and compile the catalog before merging.

Confirm that each Crowdin PR keeps the Explorer and alert keys now on `main`.
Complete coverage does not mean a native speaker has reviewed the wording.
[TRANSLATING.md](TRANSLATING.md) explains the review status.

## Submitting changes

1. Fork the repository and create a topic branch.
2. Make your change, with tests where the data layer is involved.
3. Run `swift test` and `swift format lint --strict` and make sure both pass.
4. Update [CHANGELOG.md](CHANGELOG.md) under "Unreleased" if the change is
   user-visible.
5. Open a pull request using the template, describing what changed and why, and
   how you verified it.

Release preparation and publishing are separate from normal contribution work.
Do not run `Scripts/deploy.sh` as a validation step: it can change versions,
install the app, upload assets, and make a release public.
Maintainers should follow the [release checklist](docs/release-checklist.md).

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
