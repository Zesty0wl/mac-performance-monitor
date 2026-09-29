# Release Checklist

## 2.2.1 Release

The maintainer approved publishing 2.2.1 on 23 September 2026 to fix
[#117](https://github.com/Zesty0wl/mac-performance-monitor/issues/117).
[Version 2.2.1, build 261](https://github.com/Zesty0wl/mac-performance-monitor/releases/tag/v2.2.1.261)
became the latest stable release at **19:50:40 UTC** that day. The previous
public release was 2.2.0 build 260.

### Cause

2.2.0 was the first release built with Xcode 27. Its default SwiftPM build
engine (Swift Build) writes the deployment target into `LC_BUILD_VERSION` as
the SDK version. The shipped binary recorded `minos 15.0, sdk 15.0`, so macOS 26
and 27 gave it the pre-Liquid Glass compatibility appearance. 2.1.0, built with
Xcode 26, recorded `sdk 26.5`. A one-file package reproduces it: the default
engine records `sdk 15.0` and `--build-system native` records `sdk 27.0`.

`Scripts/build.sh` now passes the real SDK version to the linker for all three
executables. `Scripts/bundle.sh` fails if the app binary records an SDK older
than 26. Check this on every release build:

```sh
otool -l "build/Mac Performance Monitor.app/Contents/MacOS/Mac Performance Monitor" \
  | grep -A4 LC_BUILD_VERSION
```

### Verification Record

- The annotated tag `v2.2.1.261` pins squash commit
  `1e35ec8288992432e7459afcf2befedb97b41b4b` from
  [PR #118](https://github.com/Zesty0wl/mac-performance-monitor/pull/118).
  Its tree is identical to the branch commit that was built and signed.
  [Hosted CI](https://github.com/Zesty0wl/mac-performance-monitor/actions/runs/35911159858)
  passed on `macos-15` and `xcode-27` for that commit.
- The local suite ran **1,030 tests**: 183 app, 17 IPC, and 830 Core, with 15
  expected opt-in skips and no failures. Strict lint and the localization check pass.
- The app, helper, and inference worker all record `minos 15.0, sdk 27.0`.
  The new bundle guard rejects the 2.2.0 binary. The Liquid Glass toolbar was
  confirmed on screen under macOS 27 with the same build change.
- Apple accepted app notarization `0176d3c3-c97e-4d9b-a1d1-d0462b896ae7` and
  installer notarization `301f238d-1456-4296-b4e1-ce6f0f8463bc`. Both staples
  validate and Gatekeeper accepts both as Notarized Developer ID.
- The Sparkle archive signature verifies with the public key shipped in 2.2.0
  (`SUPublicEDKey` is unchanged). The feed embeds these release notes and names
  build 261, version 2.2.1, macOS 15, arm64, and an archive length of 33,453,835 bytes.
- The draft assets matched the local files byte for byte before publication.
  The latest installer and feed, plus the versioned ZIP, return HTTP 200
  without a sign-in and hash to the values below.
- The signed build installed to `/Applications` from `install.sh --no-launch`.
  This pass did not run a Sparkle UI upgrade from 2.2.0 or a Homebrew install.

| Artifact | SHA-256 |
| --- | --- |
| `MacPerformanceMonitor.pkg` | `66be86a8f771b6b3ef32d1e8531085d311f50a5b0ea47a2689b6033f0f1f74c2` |
| `MacPerformanceMonitor-2.2.1.261.zip` | `87dd7eb71750cd290833c5b9a8bcdd082740b847899ac20bb842860fa1a183a6` |
| `appcast.xml` | `1bdfdcf3a1005f3d637f512858c55b39860af47cd16e02df72a87becebca1049` |

This repository's cask targets 2.2.1.261 with the published package checksum.
Homebrew's bot handles the official catalog bump. `brew fetch` was not run against the tap copy.

## 2.2.0 Release

The maintainer approved publishing 2.2.0 on 20 September 2026.
[Version 2.2.0, build 260](https://github.com/Zesty0wl/mac-performance-monitor/releases/tag/v2.2.0.260)
became the latest stable release at **13:37:27 UTC** that day. The previous
public release was 2.1.0 build 236.

- [x] Approve version 2.2.0 and retain the disclosed Preview and experimental limits.
- [x] Finalize the dated changelog and release notes, including version-pinned links.
- [x] Commit and push the exact release source, excluding private local notes and data.
- [x] Pass hosted CI on macOS 15 and the Xcode 27 runner.
- [x] Sign and notarize the app and installer with the existing Apple identities.
- [x] Verify nested signatures, staples, package contents, languages, and installed launch.
- [x] Embed the release notes in Sparkle and verify the archive with the public key from 2.1.0.
- [x] Pin the release tag to the verified source commit and check downloaded draft assets.
- [x] Publish the same bytes and verify public installer, archive, and update-feed URLs.
- [x] Update and test this repository's Homebrew cask against the final package checksum.

### Verification Record

- The annotated tag `v2.2.0.260` pins source commit
  `536952c51e2b35fbe6743b35d023b216edc0f9f7`.
  [Hosted CI](https://github.com/Zesty0wl/mac-performance-monitor/actions/runs/35513524793)
  passed on both runners: **1,022 tests**, 15 expected opt-in skips, no failures.
  The Xcode 27 run includes 175 app, 17 IPC, and 830 Core tests.
- The first CI run found a navigation-test assumption about AppKit on macOS 15.
  The final commit fixes that test and adds a native-tab fixture. App sources,
  resources, dependencies, scripts, and release notes match the signed build's inputs.
- Apple accepted app notarization `e50c49e0-251e-43d3-bdbd-a18375f06674` and
  installer notarization `7a282948-080d-4b60-86d6-d296c7fc0e52`.
  Both use the existing Developer ID identities for team `8352865GK4`.
  Nested signatures, notarization tickets, and Gatekeeper checks pass.
- ZIP and PKG extraction produces the same files, symlinks, and permissions as
  the signed app. All **2,829 catalog keys** match in English, German, French,
  and Simplified Chinese. Package-builder warnings did not change the payload.
- After backing up the app and history, the exact ZIP bundle replaced local
  2.1.0 build 259. Version 2.2.0 build 260 launches, the helper runs, and GPU
  charts draw live readings and retained history. The backup passes SQLite's
  integrity check. Both inference runtime checks pass without network or build-folder access.
- The draft and public downloads match the checked local files byte for byte.
  The latest installer and feed, plus the versioned ZIP, return HTTP 200
  without a GitHub sign-in. Sparkle's archive signature verifies with the public key from 2.1.0.
  The feed specifies build 260, version 2.2.0, macOS 15, and arm64. Its embedded
  notes and archive length of 33,457,449 bytes match the release.

| Artifact | SHA-256 |
| --- | --- |
| `MacPerformanceMonitor.pkg` | `3a01042bf095f8ea3fce4c9ca6e6ed2a3feaafaf83becda86a50d93843fbac2c` |
| `MacPerformanceMonitor-2.2.0.260.zip` | `a56e58be76e8530c24a742fd7b2531873fd8462c98d963734ecee1c0836895cc` |
| `appcast.xml` | `4c3de4970ebd0204a2f5ad4ae155c362b22cf63d392f69842c2197257b1cc339` |

### Homebrew Status

This repository's cask now targets 2.2.0.260. Ruby syntax, Homebrew style, and
the online cask audit pass. `brew fetch` verifies the package checksum; its
cached download matches the published installer exactly.

At publication, Homebrew's official catalog still listed 2.1.0.236.
`brew livecheck --cask --autobump mac-performance-monitor` detects 2.2.0.260.
Homebrew rejects manual version-bump PRs for this cask because its bot handles
them automatically. The bot's next update and catalog refresh remain pending.
See [Homebrew distribution](homebrew-submission.md) for the official and tap paths.

The model, Siri, language, and workload checks listed below remain open.
Passing tests does not prove that an AI answer is sound. The app has no cloud
fallback. Publishing does not download model weights. This pass did not run
a full Sparkle UI upgrade or a root-level package install through Homebrew.
It did not change the website.

Private backups, screenshots, and logs remain under ignored
`build/release-verification/2.2.0.260`. They are not release assets.

## Sunday Release Preparation (20 September 2026)

Preparation used **2.1.0, build 236** (`v2.1.0.236`) as its comparison baseline.
Version 2.2.0 was proposed here and later approved in the release record above.
The completed preparation results below predate the final release build.

### Release Materials

- [x] Check all changes since 2.1.0, including work not yet committed.
- [x] Group the changelog by what users get. Include Usage Timeline, Ask, GPU,
  Neural Engine readings, saved ranges, and fixes. State the limits.
- [x] Write draft release notes. Keep download links on the public release.
- [x] Update the README and guide index.
- [x] Review the images. Refresh GPU for bandwidth history, ANE Time, ANE Power,
  and GPU awake. Check Ask and Usage Timeline too.
- [x] Check links, image paths, translated string coverage, and release wording.
  Native translation approval remains a separate check below.

### Candidate Verification

- [x] Run all tests, strict Swift lint, both language checks, and the catalog
  compiler. Record skips and the source tested.
- [x] Build an isolated optimized app and verify its packaged runtime resources.
  This is an ad-hoc-signed check, not a notarized release candidate.
- [ ] Run hosted CI on the final committed source. Confirm its toolchain tests
  the Xcode 27 AI and App Intents code, not just older-compiler fallback paths.
- [x] Test an upgrade fixture from the 2.1.0 schema with stored CPU, GPU, and
  battery readings. Retain those values and leave new GPU fields unknown.
- [ ] Test the final signed upgrade with a backed-up user database. The fixture
  above does not replace a package upgrade or a full database soak.
- [ ] Test the signed app: GPU, ANE power through the helper, Ask consent, Stop,
  and model downloads. A test fixture does not replace these checks.
- [ ] Decide whether the new experimental models should ship. Record real-model
  tests and state any gaps in coverage.
- [ ] Test Siri, Shortcuts, and older supported macOS versions.
- [ ] Get native speakers to review new text. Run a longer monitoring session.

### Local Verification

Completed on 20 September using Xcode 27 and Swift 6.4. The tested tree is local
work on `main` after `c54ca47`, not a final release commit. Source metadata and
the installed app remain **2.1.0, build 258**. No version bump, install, tag,
push, notarization, or public upload was performed during preparation.

- Full suite: **1,021 tests**, 15 expected opt-in skips, no failures. Counts are
  174 app, 17 IPC, and 830 Core tests. Tests requiring real models or explicit
  private data were not enabled for this run.
- Strict Swift lint, editor checks, shell syntax, and whitespace checks pass.
- All **2,829 catalog keys** have four-language coverage. The compiled bundle's
  English, German, French, and Simplified Chinese values match the source catalog.
  Compiler extraction found 1,238 UI keys with none missing from the catalog.
- The populated schema-v20 upgrade fixture passes. Existing CPU, GPU, and battery
  values survive; newer bandwidth, memory, awake-time, and ANE fields stay unknown.
- The optimized bundle is at `build/release-preparation/Mac Performance Monitor.app`.
  Its ad-hoc signatures pass deep and strict verification. Sparkle, App Intents
  metadata, inference resources, licences, and language bundles are present.
- MLX and GGUF runtime checks pass with outbound network and `.build` reads
  denied. Only the unprivileged inference worker links llama.cpp. The app bundle
  contains no model weights. These checks do not test real-model answer quality.

Logs are under ignored `build/release-preparation`, including `full-suite.log`,
`release-build.log`, `string-coverage.log`, and `gguf-runtime.log`. The final
release must rerun its required checks after the version and commit are fixed.

### Screenshot Audit

Reviewed on 20 September. These are documentation assets, not proof that the
final signed release has passed its smoke tests. No private Apple activity or
AI conversations were read for the new examples. The app returned to its GPU
tab after capture; recording and AI consent settings were not changed.

| Image | Action And Source |
| --- | --- |
| [GPU](images/gpu.png) | Replaced. Current-source native GPU view with sample data, six cards, bandwidth history, Preview label, and one shared caveat. |
| [Neural Engine](images/gpu-neural-engine.png) | Added. Same sample-data view, scrolled to the separate time and power charts. |
| [Ask](images/ask-preview.png) | Added. Native current-report fixture with AI off. No claim of a real model result. |
| [Usage Timeline](images/usage-timeline.png) | Added. Native fixture for an example Editor app. All activity lanes use synthetic data. |
| [Dashboard](images/dashboard.png) | Refreshed from installed 2.1.0 build 258, including current toolbar and saved 30-minute range. |
| [Processes](images/processes.png) | Refreshed from build 258. Cropped to the process overview and inspector. |
| [Energy](images/energy.png) | Refreshed from build 258. Top-of-window crop excludes the battery serial panel. |
| [Explorer](images/explorer.png) | Retained the earlier reviewed capture with populated process comparisons. The new capture had no selected processes and was less useful. |
| Network, Disk, Disk Map, Hardware, Insights | Older layouts still showed Analytics; some included identifiers or file paths. Removed from the current README gallery. Original files remain for existing links. |

Native capture tests live in the existing GPU, Ask, and Usage Timeline test
files. Raw captures remain under ignored `build/release-preparation/screenshots`.
Do not publish that folder wholesale. Only the reviewed assets above belong
in the gallery. New GPU captures are source previews, not final signed-app captures.

### Publication Hold

Install and deploy scripts are not dry runs. They can change versions, install
the app, sign files, or publish them. Get approval before those steps.

For release, confirm the version and choose a clean source commit. Run CI on
that commit. Build and sign once. Check the package and Sparkle feed with the
existing key. Download and check the draft files before making them public.
Until then, leave the cask, public feed, tags, and website unchanged.

The release workflow now runs on both `macos-15` and `xcode-27`. Local success
does not replace hosted results for the final release commit.

Before uploading, remove the draft labels and pin release-note links to the
final tag. Refresh website images with new versioned URLs in its separate repo;
this preparation does not deploy the website or change cached public assets.

## 2.1.0 Release

The maintainer approved publishing 2.1.0 from `main` on 11 September 2026.
The release build is 236; the prior public release is 2.0.0, build 231.
The draft downloads passed verification before the production feed changed.
The release became the latest stable version at 12:31:46 UTC on 11 September 2026.

### Source And Build

- [x] Start from clean `main` at `c413b5d`. Hosted CI run `34594914002`
  passed all gates. The local suite ran 849 tests with two skips and no failures.

- [x] Finalize the 2.1.0 changelog, release notes, README, and documentation index.
  Keep native translation review and missing older battery data limits visible.

- [x] Confirm Apple signing and notary access. Keep the existing Sparkle key
  and feed URL. Never generate a replacement key during a release.

- [x] Build and sign 2.1.0 build 236 with `Scripts/install.sh --no-launch`.
  The locked Mac blocked keychain access. After unlock, notarization resumed
  with the same signed bytes, without a rebuild or another build increment.

- [x] Package with `Scripts/deploy.sh --resume --skip-upload`.
  App, helper, installer, notarization, staples, and Gatekeeper checks pass.

- [x] Embed the release notes in the appcast. Verify the archive signature with
  the public key from the shipped 2.0.0 bundle. Archive size, version, download
  URL, minimum macOS 15.0, arm64 requirement, and embedded notes match.

- [x] Extract both artifacts. All files and symlinks match the signed source
  and installed app. All 2,499 catalog keys resolve in all four language bundles.

- [x] Test an upgrade from a populated v18 database. Old charge and temperature
  survive the new migrations; missing Energy values remain unknown. The full
  local suite passes 850 tests with two skips, plus formatting and both
  localization checks. The release build compiles the String Catalog.

- [x] Install the verified bundle and launch it. The helper is running and
  Energy draws live readings, retained charts, and accessory batteries. A
  private history backup passes SQLite integrity checks. This is a smoke test,
  not an end-to-end Sparkle UI upgrade or an extended soak.

- [x] Push the final source and build metadata at
  `3922772545fa38d1325f73efd218c393f2b654ff`. The worktree was clean and
  [release CI](https://github.com/Zesty0wl/mac-performance-monitor/actions/runs/34598750928)
  passed every gate in 5m40s on that exact commit.

### Publication

- [x] Create the annotated tag `v2.1.0.236` at the verified commit above.
  The remote tag resolves to that commit; no old tag moved.

- [x] Create a draft with that tag and the signed ZIP, package, and feed.
  Downloaded draft assets match the local files byte-for-byte. The downloaded
  ZIP passes Ed25519 verification with the public key from 2.0.0.

- [x] Publish [2.1.0 build 236](https://github.com/Zesty0wl/mac-performance-monitor/releases/tag/v2.1.0.236)
  as the latest stable release. The public installer, archive, and latest feed
  return HTTP 200 and match the verified files. The feed names build 236,
  keeps the macOS 15 and arm64 limits, and includes the release notes.

- [x] Update the repository cask with the exact public package checksum.
  Ruby syntax, checksum comparison, and Homebrew style checks pass.
  Homebrew's separate public cask can lag this update; it does not control Sparkle.

### Manual Coverage

Native translation review, a fresh end-to-end Sparkle UI update from 2.0.0,
and an extended workload soak remain separate from automated checks. Do not
claim them from unit tests or a short launch check. Runtime estimates still
need checks across real workloads. Synthetic daily data is not a year-long soak.

### Verified Artifacts

Apple accepted the app submission `4718bd42-2410-4100-9245-926cff280076`
and the package submission `473b14b1-bd46-4244-96f7-a52cfe359022`.
Both use Apple team `8352865GK4`. The existing Sparkle key is unchanged.
These hashes match the local artifacts, draft downloads, and public downloads:

```text
MacPerformanceMonitor.pkg
04e88fb0a8269495f9bbd51ecc1f7c2363fcec47d4912c8e05798165c3af9ea1

MacPerformanceMonitor-2.1.0.236.zip
b3a77e2a703e39af05ec2a44a8386dbced023578862878f6a30e93f4052f6f24

appcast.xml
4c69659aeb341e68e620c4c5cfb0fc81e51ca5f10dedc76966b9bd3575a2cf36
```

## 2.0 Release Record

The maintainer approved publishing 2.0.0 from `main` on 10 September 2026.
Keep unfinished checks open until someone verifies them. Native translation
review remains a disclosed limitation, not a completed check.

### Source Status

Preparation began on `2.0.0` at `c3508bc`, version 2.0.0, build 230.
The preceding public release is 1.7.1, build 206. The final release build and
verification results will be recorded below. Keep the cask on a public package.

- [x] Review the root README, changelog, contributor, security, and translation guides.

- [x] Prepare [release notes](../RELEASE_NOTES.md) and a [documentation index](README.md).

- [x] Keep the real Explorer and Dashboard screenshots from the running app.

- [x] Identify the [hosted CI failure](https://github.com/Zesty0wl/mac-performance-monitor/actions/runs/34489995543)
  at `c3508bc`: a cyclic-growth test fixture exceeded the Swift type-checking
  budget. Split it into typed intermediate values; its tests and lint pass locally.

- [x] Run the local build, full test suite, strict formatting, both string
  coverage checks, and String Catalog compilation on the preparation tree.

- [x] Audit all 436 keys added since 1.7.1. All four languages have values.
  Verify all 2,437 catalog keys through each compiled language bundle and
  correct the French Explorer capacity warning. See the
  [translation audit](../TRANSLATING.md#coverage-audit-10-september-2026).

- [x] Commit the preparation changes and fast-forward `main` to `8a8155a`.
  [Hosted CI](https://github.com/Zesty0wl/mac-performance-monitor/actions/runs/34502106577)
  passed build, tests, lint, source coverage, catalog compilation, and compiler
  string coverage on that commit.

- [x] Push build 231 metadata at `86a77f82e67b23ab2fa27644ec31dce546376a10`.
  [Final release CI](https://github.com/Zesty0wl/mac-performance-monitor/actions/runs/34503581438)
  passed every gate on that exact commit.

- [ ] Review the 305 new `needs_review` entries in each of Simplified Chinese,
  German, and French with native speakers. Coverage is not native approval.

- [ ] Review every gallery image and translated compact view on the final app.
  The source catalog has full coverage, but generated wording still needs review.

Local verification on 10 September 2026 used Swift 6.3.3: 786 tests, two skips,
and no failures. The skips need a recorded database and a live hardware capture.
This verifies the preparation tree, not a future commit or signed installer.

### Build 231 Checks

- [x] Build 2.0.0, build 231 from `main` without a marketing-version bump.
  The app and helper share the expected Apple team identity.

- [x] Apple accepted the app for notarization: `30fd89eb-bb15-4386-9d1a-d86b59b5acbf`.
  The installed copy passes signature, stapling, and Gatekeeper checks.

- [x] Apple accepted the package: `4061e2ff-2c8f-47df-b2e2-3bdbcdec2f72`.
  The installer signature, staple, and Gatekeeper checks pass.

- [x] The installed app opens its window and draws Dashboard history and live
  readings. The helper is running. This is a launch check, not a full soak.

- [x] The Sparkle ZIP signature verifies against the public key shipped in
  1.7.1. The feed advances build 206 to 231, keeps macOS 15 and arm64 limits,
  and names the exact versioned archive with its correct byte count.

- [x] Verify the draft downloads byte-for-byte, publish, and check all three
  public asset URLs. The latest installer and appcast, plus the versioned ZIP,
  return HTTP 200 and match the verified files.

Native translation review, a fresh end-to-end 1.7.1 update, and a new extended
soak remain unverified in this release pass. Earlier automated regression and
fixture checks do not replace those manual checks.

### Published Release

[2.0.0 build 231](https://github.com/Zesty0wl/mac-performance-monitor/releases/tag/v2.0.0.231)
was published as the latest stable release on 10 September 2026 at 16:45 UTC.
The annotated tag `v2.0.0.231` points to the tested release commit above.
The appcast embeds the release notes and uses the existing Sparkle signing key.

Both the installer and ZIP contain the same signed app. All 2,437 catalog keys
resolve from all four languages in each extracted bundle. The following hashes
match the unauthenticated public downloads:

```text
MacPerformanceMonitor.pkg
746eee1508474c775bc98934f18592c58947de7a68ec30d2c98d703fffd2c63c

MacPerformanceMonitor-2.0.0.231.zip
a9af4faa58b7c91cadb29ddf4663c12384f001123ba54e38402058ef66a1fd69

appcast.xml
2904d4cebd9990c7bb5b2eecb2a94ab4e3a16059ee25dc7d6492015374ea4a11
```

The repository's cask now uses that published package hash. Homebrew's separate
public cask can lag the release; its update is not part of the Sparkle rollout.

### Local Checks

Run from the repository root. These commands do not publish, sign, or install:

```sh
swift build
swift test
swift format lint --strict --recursive Sources Tests Package.swift
Scripts/check-localization.py
Scripts/check-string-coverage.py
xcrun xcstringstool compile Localizations/Localizable.xcstrings --output-directory /tmp/macperf-release-localizations
git diff --check
```

Inspect the test summary, including skips. The existing-database alert replay
is opt-in and read-only; see [Adaptive alerts](adaptive-alerts.md#verification).
It does not prove the new paging-strain rule matches real workloads, because
old history did not record those rates. Keep a longer live alert soak on the
release gate list.

Validate Markdown links and image references too. Check badge and download
links against the branch or release that readers will actually open.

### Upgrade And Runtime Gates

- [ ] Test an upgrade from the published 1.7.1 package with a backup of its data.
  Verify retained history and new schema fields without inventing old values.

- [ ] Verify an ordinary launch opens the window and a login launch stays quiet.
  Check independent menu bar, history, and Dock settings, including old mode migration.

- [ ] Verify helper authorization, app/helper identity checks, and full coverage
  on the final signed bundle. Ad-hoc tests do not cover this.

- [ ] Exercise Explorer with one and eight processes, exact-time navigation,
  Command-scroll, old history, missing data, CSV, and trace import/export.

- [ ] Exercise alerts with stable high swap, rapid growth and escalation,
  settling, sleep/wake, restart, recording off, snooze, and Quiet Evaluation.
  Confirm critical-pressure protection and notification permissions.

- [ ] Check light/dark appearance and all four languages, especially menus,
  evidence labels, first-open sheets, and long process names.

- [ ] Check disk and network menus, GPU and thermal readings, Disk Map,
  hardware inventory, and the process inspector on supported hardware.

- [ ] Run an extended signed-app session for CPU, memory, history size, and
  alert noise. Record the duration and workload rather than declaring a soak
  from a short unit test.

### Publishing Hazards

Read [deploy.sh](../Scripts/deploy.sh) before running it. Its default mode bumps
the patch version. From this branch, plain `Scripts/deploy.sh` would produce
2.0.1; `--major` would produce 3.0.0. Neither is the intended 2.0.0 release.

Use the existing no-bump path: build the already-versioned source with
`install.sh --no-launch`, then package with `deploy.sh --resume`. The install
step increments the build number and installs the signed app. It is not a
read-only check. `--skip-upload` avoids GitHub publication but still packages,
signs, and notarizes; it is not an offline dry run.

The publisher creates a release without `--target` or a notes file. If the tag
does not exist, GitHub can create it from the default branch, not the branch
whose app was built. Resolve this before publication: explicitly create the
tag at the verified release commit, or update and test the publisher to pin
that commit. Never move an already-published tag to repair an incorrect build.

The publisher also replaces assets if a release already exists. A retry must
reuse the intended source and build. Do not overwrite a released build with
different bytes without a deliberate release decision.

Keep the existing Sparkle EdDSA signing key. A replacement key would break
updates for installed apps. Recover the original key if it is missing; do not
generate a new one as part of this release.

### Approved Release Sequence

Use a draft release so the production feed stays unchanged until the uploaded
assets have been checked. This path publishes the exact verified package;
it does not rebuild the package between checking its hash and uploading it.

1. Choose the final source commit and publishing branch. If merging into `main`,
   get CI green there before building. Keep the same source through packaging.

2. Finalize the release notes and changelog date. Remove their draft notices.
   Update the README and security policy's pre-release wording. Check the CI
   badge and source-build branch if the documentation moves to `main`.

3. Build the existing 2.0.0 version, without a marketing-version bump:

   ```sh
   Scripts/install.sh --no-launch
   Scripts/deploy.sh --resume --skip-upload
   ```

   Both commands use signing credentials and Apple notarization. If a prompt
   needs a password, enter it directly in your terminal. Never put it in chat.

Convert the release notes to an HTML fragment beside the ZIP, using the same
filename stem. Regenerate the appcast with `--embed-release-notes` and the
existing key. Check the embedded text and signature before uploading the feed.

4. Verify source/app version and build parity, signatures, notarization, and stapling. Run the smoke tests above and record any manual checks not run. Use full URLs in the release notes. Commit and push the source, notes, and build metadata, then verify CI on that commit. Keep the worktree clean and HEAD equal to upstream.

5. Pin a new tag to that verified commit. Confirm the tag does not already exist
   locally or remotely. The following commands publish a tag and are not a check:

   ```sh
   release_commit="$(git rev-parse HEAD)"
   release_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
   release_tag="v2.0.0.${release_build}"
   git tag -a "$release_tag" "$release_commit" -m "Mac Performance Monitor 2.0.0 (build ${release_build})"
   git push origin "$release_tag"
   ```

6. Create a new draft release at that tag with `gh release create --draft --verify-tag --target "$release_commit" --notes-file RELEASE_NOTES.md`. Attach the signed ZIP, package, and appcast from step 3. Do not overwrite an existing release.

7. Download the draft assets and verify their hashes and Sparkle signature. Check the appcast version, minimum macOS, archive URL, and archive size. Publish with `gh release edit "$release_tag" --draft=false --latest` only after those checks pass. Then check the public latest-release download URLs.

8. Update the local cask version and checksum from that exact published package, then commit and push it to `main`. This draft workflow bypasses the publisher's automatic cask edit. Check Homebrew's separate public cask update; its timing is not guaranteed.

### Evidence To Retain

Record the final commit, build, tag, CI URL, test results and skips, upgrade/soak
notes, notarization results, and hashes of the published files. Keep private
keys, certificates, local histories, and incident logs out of the repository.
Do not publish with unresolved build, signature, tag, or feed failures.
Record manual checks not run and keep known limits visible in the release notes.