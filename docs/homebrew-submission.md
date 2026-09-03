# Homebrew submission

How Mac Performance Monitor got into Homebrew, and how the cask stays current
afterwards. The cask was accepted into
[Homebrew/homebrew-cask](https://github.com/Homebrew/homebrew-cask) on
2026-09-03 ([PR #283646](https://github.com/Homebrew/homebrew-cask/pull/283646)),
so `brew install --cask mac-performance-monitor` works without a tap. The
canonical cask still lives in this repository at
`Casks/mac-performance-monitor.rb`; the homebrew-cask copy is identical.

## Why a cask (not a formula)

This is a signed, notarized GUI app distributed as a binary `.pkg`. Homebrew
ships apps like this as casks. A formula (building from source) is not
appropriate: the release artifact is the notarized bundle with the embedded
privileged helper, Sparkle framework and stapled Gatekeeper ticket, none of
which a source build reproduces.

## Acceptance criteria, checked

Homebrew/homebrew-cask requires new casks to be notable and installable
without surprises:

- **Notability:** the GitHub repository passes Homebrew's popularity bar
  (over 75 stars; 239 at submission time).
- **Stable, versioned download:** each release tag hosts
  `MacPerformanceMonitor.pkg` as a GitHub Release asset, so
  `releases/download/v<version>/MacPerformanceMonitor.pkg` is a permanent
  per-version URL. The cask pins it with a checksum.
- **Signed and notarized:** the pkg and the app inside it are Developer ID
  signed, notarized and stapled (Gatekeeper passes offline).
- **No conflicting token:** `brew info --cask mac-performance-monitor`
  reports no existing cask.

## What the cask declares

- `pkg` install from the per-tag release asset. The old `verified:`
  parameter (once required when the download domain differed from the
  homepage) is deprecated in current Homebrew and must be omitted; their CI
  rejects casks that still carry it.
- `auto_updates true`: the app updates itself via Sparkle, so
  `brew upgrade` skips it unless `--greedy`.
- `depends_on arch: :arm64` and `macos: :sequoia`: the app is Apple silicon
  only and needs macOS 15 or later (the bare symbol means "at least" in the
  current cask DSL; `maximum_macos` is the capping stanza).
- `uninstall`: unloads the privileged helper LaunchDaemon
  (`uk.co.bzwrd.macperfmonitor.helper`), quits the app by bundle id, and
  forgets the pkg receipt (`uk.co.bzwrd.macperfmonitor`).
- `zap`: removes the sample database and settings
  (`~/Library/Application Support/MacPerformanceMonitor` plus the standard
  per-bundle-id preference, cache and saved-state paths).
- No `livecheck` block: Homebrew's default strategy for a GitHub release
  URL already follows the latest release, and this repo tags nothing
  without a release (maintainer feedback on the submission PR; an explicit
  block is only for repos with pre-releases or release-less tags). The
  release tags are 4-part (`v1.5.0.198`: marketing version plus build
  number), so the cask `version` is the 4-part string and the URL
  interpolates it directly.

## Local validation (run before submitting)

```sh
brew style Casks/mac-performance-monitor.rb
brew tap-new local/test --no-git
cp Casks/mac-performance-monitor.rb "$(brew --repository)/Library/Taps/local/homebrew-test/Casks/"
brew audit --cask --online --new local/test/mac-performance-monitor
brew install --cask local/test/mac-performance-monitor   # optional end-to-end test
brew uninstall --cask local/test/mac-performance-monitor
brew untap local/test
```

## Submitting to Homebrew/homebrew-cask

1. Fork `Homebrew/homebrew-cask` and clone the fork.
2. Copy `Casks/mac-performance-monitor.rb` to `Casks/m/mac-performance-monitor.rb`
   (homebrew-cask shards casks by first letter).
3. Branch, commit as `mac-performance-monitor 1.5.0.198 (new cask)`.
4. Run their checks from the tap checkout:
   `brew audit --cask --online --new mac-performance-monitor` and
   `brew style Casks/m/mac-performance-monitor.rb`.
5. Open the PR. The template asks to confirm the audit and style runs and
   that the app installs cleanly; maintainers usually respond within days.
6. One point worth volunteering in the PR description: the author of the app
   is submitting it, the pkg is notarized, and the tag scheme is
   deliberately 4-part so GitHub never mistakes a build for a pre-release.

## After acceptance

- Users install with `brew install --cask mac-performance-monitor`.
- Homebrew's bump bot (BrewTestBot) follows the GitHub release URL and opens
  version-bump PRs on its own when a new release appears. No `livecheck`
  block is needed: the bot bumped 1.5.0.198 to 1.7.0.205 about five hours
  after the new cask merged. A normal `Scripts/deploy.sh` release therefore
  needs no manual Homebrew work. If a bump is ever needed by hand:
  `brew bump-cask-pr mac-performance-monitor --version <X.Y.Z.B>`.
- Keep `Casks/mac-performance-monitor.rb` in this repo in sync when the
  stanzas change (new uninstall paths, changed minimum macOS), and mirror
  such changes into homebrew-cask with a PR.

## The tap in this repository

The cask here is still installable through the tap, and `Scripts/deploy.sh`
rewrites its version and checksum on every release, so it is always the
first place a new build appears:

```sh
brew tap zesty0wl/mac-performance-monitor https://github.com/Zesty0wl/mac-performance-monitor
brew install --cask zesty0wl/mac-performance-monitor/mac-performance-monitor
```

People who installed from the tap before the homebrew-cask merge need do
nothing. Homebrew resolves a bare cask name to homebrew-cask first and never
treats it as ambiguous with a third-party tap (`Cask::CaskLoader::FromNameLoader`),
and `auto_updates true` means Sparkle keeps existing installs current
regardless of which tap they came from.
