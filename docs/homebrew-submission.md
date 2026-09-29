# Homebrew Distribution

Users can install the app from Homebrew's official catalog without adding a tap:

```sh
brew install --cask mac-performance-monitor
```

The catalog can lag a new release while Homebrew's bot updates the cask.
Sparkle and the direct installer can offer the new version sooner.

The cask in this repository is
[Casks/mac-performance-monitor.rb](../Casks/mac-performance-monitor.rb).
Homebrew keeps its own copy. Check both when the version, install steps, or
supported Mac models change.

## Prepare A Release

Keep the cask on the latest published package while the next version is in development.
Do not point its version or URL at a test build with no public download.
The final build number and hash must come from the published signed package.

Use the hash after signing, notarization, and stapling. Publish those exact bytes.
A `--skip-upload` package is suitable if you upload it without rebuilding it.
Running `deploy.sh --resume` again recreates the package and can change its hash.
Follow the [release checklist](release-checklist.md) for the source and tag checks.

## What The Cask Does

Homebrew uses a cask for a packaged app. Building from source is a different
path: it does not produce the signed release package or Apple's notary ticket.
The release includes the app, its helper, and Sparkle for updates.

- `pkg` installs the package from its release tag. The checksum pins that
  file. Keep the old `verified:` option out; Homebrew rejected it during the
  original review.

- `auto_updates true` tells Homebrew that Sparkle can update the app.
  A normal `brew upgrade` skips it; `--greedy` includes it.

- `depends_on` limits installs to Apple silicon and macOS 15 or later.

- `uninstall` stops the helper, quits the app, and forgets the package receipt.
  It does not erase the user's history.

- `zap` removes local app data. This includes history, settings, caches, and
  the new alert files in `~/Library/Application Support/MacPerformanceMonitor`.
  Treat this as data deletion, not routine cleanup after a test.

- The cask has no `livecheck` block. Homebrew's GitHub release strategy follows
  published releases. The four-part version is the app version plus its build
  number, for example `2.2.0.260`.

## Check An Update

Check style from the repository root:

```sh
brew style Casks/mac-performance-monitor.rb
```

For an audit, use a local test tap. The following commands create that tap and
copy the cask into it. The audit needs network access, but does not install the
app. Use a fresh tap name if `local/test` already exists.

```sh
brew tap-new local/test --no-git
mkdir -p "$(brew --repository)/Library/Taps/local/homebrew-test/Casks"
cp Casks/mac-performance-monitor.rb "$(brew --repository)/Library/Taps/local/homebrew-test/Casks/"
brew audit --cask --online local/test/mac-performance-monitor
brew fetch --cask local/test/mac-performance-monitor
```

Test the package on a test Mac or with backed-up app data. These commands
install and remove the app; they are not read-only checks:

```sh
brew install --cask local/test/mac-performance-monitor
brew uninstall --cask local/test/mac-performance-monitor
brew untap local/test
```

## After Each Release

Update this repository's cask with the final version and hash. Check the public
download, then commit and push to the branch the tap reads.

Homebrew's bot handles version bumps for the official cask. Its CLI rejects
manual bump PRs for this cask. Check that release detection finds the new version:

```sh
brew livecheck --cask --autobump mac-performance-monitor
```

Wait for the bot's PR to merge and the catalog to refresh. Release detection
alone does not mean the official install command will fetch the new version.
Check `brew info --cask mac-performance-monitor` before claiming it is available.

To upgrade an existing install after the catalog refreshes:

```sh
brew update
brew upgrade --cask --greedy mac-performance-monitor
```

Changes to install rules, minimum macOS, or uninstall paths also need a PR in
Homebrew's copy. A version bump alone will not carry those edits across.

## This Repository's Tap

The separate tap remains available:

```sh
brew tap zesty0wl/mac-performance-monitor https://github.com/Zesty0wl/mac-performance-monitor
brew install --cask zesty0wl/mac-performance-monitor/mac-performance-monitor
```

Existing tap installs can still receive Sparkle updates. Users do not need to
reinstall to change where Homebrew finds the cask.

## Original Submission

Homebrew accepted the cask on 3 September 2026 in
[PR #283646](https://github.com/Homebrew/homebrew-cask/pull/283646).
The repository had 239 stars, the cask name was free, and the package passed
the signing and install checks. These are facts about that submission, not
proof that a future package passes.

The original PR added `Casks/m/mac-performance-monitor.rb` to Homebrew's fork.
It used the title `mac-performance-monitor 1.5.0.198 (new cask)` and ran
`brew style` plus `brew audit --cask --online --new`. Future releases update
that existing cask, not submit a second new one.

The bot moved the cask to 1.7.0.205 about five hours after the first merge.
That was one observed update, not a promise about the next release.
