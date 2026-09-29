# Translating Mac Performance Monitor

Every language lives in one file:

```
Localizations/Localizable.xcstrings
```

That is an Apple **String Catalog**: a JSON document holding every key, the
English source text, and one entry per language. There are no per-language
source folders to keep in sync. Adding a language also needs entries in the
Settings language picker and locale mapping.

You do not need Xcode to translate. You do need it to build the app, because
the catalog is compiled by `xcstringstool`, which ships inside Xcode.

## The easy way: Crowdin

You can translate in a web editor with no git, no JSON and no Xcode:

**https://crowdin.com/project/mac-performance-monitor**

Sign in (a GitHub account works), pick your language, and start. The editor
shows the English, a note on where the string appears in the app, protected
placeholders for the format specifiers, and one box per plural form your
language needs. About once an hour Crowdin opens a pull request here with
whatever changed; we review it like any other, and your strings ship in the
next release.

If your language is not listed, open an issue asking for it. Only the
maintainers can add a target language, and we will do it the same day. We also
add the Settings picker entry when the first strings for a new language land,
so on Crowdin you never touch code.

Pick one route per language. If a language is being translated on Crowdin,
send corrections there rather than as catalog pull requests, so the two do not
overwrite each other. Everything below describes the GitHub route, and the
rules further down apply either way.

## AI-generated languages

The initial German and French translations were generated on 2026-09-03 by
Claude Fable 5.1, Anthropic's AI model. They follow Apple's macOS terminology,
informal "du" in German, and "vous" in French. Later 2.0 strings include further
AI-generated translations in German, French, and Simplified Chinese. Their
catalog comments identify them; they still need native-speaker review.

- Use Crowdin approval to track native review. A generated string is not
  reviewed just because it has a translation or passes the coverage checks.

- Settings shows a notice under the language picker while a machine-translated
  language is active, naming the model and pointing here.

- New generated entries use `needs_review` and a provenance comment in the
  catalog. Crowdin can rewrite the state during sync, so check its approval
  status rather than interpreting `translated` as proof of human review.

To improve one: fix it on Crowdin, or send a catalog pull request. When a
native speaker has been through a whole language, a maintainer removes it from
`AppLanguage.machineTranslated` in
`Sources/MacPerfMonitor/Settings/AppLanguageManager.swift` and the notice goes
away. Native-speaker review of these two languages is one of the most useful
contributions the project can receive right now.

One Crowdin quirk to know: when Crowdin imports translations from the
repository it can replace a no-break space with a plain space, and its next
pull request then carries that back here. French typographic spaces before
`:` `;` `?` `!` are therefore best entered or corrected in Crowdin's editor,
where they are kept as typed. Do not fight a whitespace-only change in a
Crowdin pull request; merge it and fix the string on Crowdin.

## Adding a language on GitHub

1. Open `Localizations/Localizable.xcstrings`. If you have Xcode, double-click
   it for a table view with a language picker and a progress bar. If not, it is
   plain JSON and any editor will do.

2. For each key, add your language beside the existing ones:

   ```json
   "Rescan" : {
     "comment" : "Disk Map",
     "extractionState" : "manual",
     "localizations" : {
       "en" :      { "stringUnit" : { "state" : "translated", "value" : "Rescan" } },
       "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "重新扫描" } },
       "fr" :      { "stringUnit" : { "state" : "translated", "value" : "Analyser à nouveau" } }
     }
   }
   ```

   Use the BCP 47 code macOS uses: `fr`, `de`, `es`, `ja`, `pt-BR`, `zh-Hant`.

3. Update `Sources/MacPerfMonitor/Settings/AppLanguageManager.swift`. Add an `AppLanguage` case. Set its native name in `title` and its locale in `locale`. The catalog and locale must use the same language code.

4. Build, switch to your language in Settings, and click through the app:

   ```sh
   Scripts/run.sh
   ```

5. Run the checks below, then open a pull request.

```sh
Scripts/check-localization.py
Scripts/check-string-coverage.py
xcrun xcstringstool compile Localizations/Localizable.xcstrings --output-directory /tmp/macperf-localizations
```

**Partial new languages are welcome.** Missing keys fall back to English.
The four languages already declared complete (`en`, `zh-Hans`, `de`, and `fr`)
must keep full coverage. Add an explicit English value for every key, even
when it matches the key text. A missing value fails the catalog checks.

## Reviewing 2.0

The `2.0.0` branch adds Explorer, chart statistics, and adaptive alerts. Check
the new strings in their actual views, including compact menu panels. Preserve
these distinctions:

- **Watching** and **Settling** are quiet observations, not active warnings.

- **Waiting for fresh data** means unknown evidence, not confirmed recovery.

- **Sustained memory growth** is not a diagnosis of a memory leak.

- **Recorded range**, an average, and **Not recorded** describe different
  evidence. A source interval is not an exact reading at every instant.

Read [Adaptive alerts](docs/adaptive-alerts.md) and the
[Explorer guide](docs/explorer-design.md) for context. When reconciling a
Crowdin PR with the release branch, preserve both new source keys and reviewed
translations. Do not replace the complete catalog with one side of a conflict.

### Coverage Audit: 10 September 2026

The catalog has 2,437 keys, including 436 added since `v1.7.1.206`.
All 436 new keys have nonempty values in English, Simplified Chinese, German,
and French. This includes Explorer, chart details, alerts, and their settings.

Both coverage checks and Apple's catalog compiler passed. All 2,437 keys
resolved from each compiled language bundle through Foundation. Plain string
values matched the catalog, not an English fallback. The French comparison
limit now means that Explorer is full, not that it is complete.

Native review is still pending for 305 new entries in each of Simplified
Chinese, German, and French. They remain marked `needs_review`. The other
entries' `translated` state does not prove native approval either. Check Crowdin
review status and the final app layout before signing off the language.

These counts describe this audit, not future changes to the branch. The
[release checklist](docs/release-checklist.md) keeps the remaining checks open.

## The rules that actually matter

**Keep format specifiers exactly as they appear.** `%@` is a piece of text,
`%lld` a whole number, `%.1f` a decimal. Their number and their types must
match the English. If your language needs a different word order, number them:

```
"en" : "%@ in %@ items"
"de" : "%2$@ Objekte, %1$@"
```

Getting this wrong is the one mistake that can crash the app rather than just
read badly, so `check-localization.py` treats it as an error.

**Plurals belong in the catalog, not in the sentence.** Do not translate
`"%lld cores"` as one string if your language inflects. Use a plural variation
and give every category your language needs. Russian needs four, Arabic six,
Chinese one:

```json
"%lld cores" : {
  "localizations" : {
    "ru" : { "variations" : { "plural" : {
      "one"   : { "stringUnit" : { "state" : "translated", "value" : "%lld ядро"  } },
      "few"   : { "stringUnit" : { "state" : "translated", "value" : "%lld ядра"  } },
      "many"  : { "stringUnit" : { "state" : "translated", "value" : "%lld ядер"  } },
      "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld ядра"  } }
    } } }
  }
}
```

macOS picks the right one using the CLDR rules for your language. Never splice
a plural suffix in as an argument: that cannot survive translation.

**Match what macOS itself says.** For a system tool, the most helpful
translation is usually the one Apple already uses. Check System Settings and
Activity Monitor in your language for "Memory", "Disk", "Network", "Battery",
"Energy" and similar, and match them, even when a more literal translation
exists.

**Leave these in English:** product and protocol names (`CPU`, `GPU`, `NVMe`,
`APFS`, `Wi-Fi`, `Thunderbolt`, `Rosetta`, `Finder`, `Dock`), and anything that
looks like a command someone types (`brew cleanup`, `xcrun simctl`).

**Short words are often deliberately ambiguous.** Some keys are longer than
what they display, because English reuses one word where other languages
cannot. `"Low Power Mode on"` displays "On" in English but lets you write
whatever your language needs. Translate the *meaning the key describes*, not
the key text. The `comment` field tells you where the string appears.

**Watch the length.** German runs roughly 30% longer than English and many
strings sit in a fixed-width menu bar panel. Check yours in the app.

## Finding what still needs work

```sh
Scripts/check-localization.py --list-missing   # untranslated keys
Scripts/check-localization.py --list-stale     # entries no longer used
Scripts/pseudolocalize.sh                      # find hardcoded English, see below
```

`pseudolocalize.sh` launches the app with every translatable string wrapped as
`[# like this #]`. Anything still showing plain English is a string that never
reaches the catalog, which is a bug worth reporting even if you are not fixing
it. Anything clipped is a layout that will break in a long language.

## How the build uses this

```
Localizations/Localizable.xcstrings          the only thing you edit
  -> xcstringstool compile                   run by Scripts/bundle.sh
  -> Contents/Resources/<lang>.lproj/        build output, not in the repository
```

Compiled `.lproj` files are generated. Do not commit them, and do not edit them:
your change would be overwritten on the next build.

## If the English changes

You may see a key's English wording change between releases. Translations are
carried across automatically when that happens, using
`Scripts/rename-localization-key.py`, so your work is not lost and you will not
be asked to redo it. If a rewording makes a translation wrong, the string is
worth revisiting, and flagging it in an issue is welcome.

## Credit

Translators are credited in the release notes and in
[CHANGELOG.md](CHANGELOG.md). Thank you for making the app usable to more
people than its author can reach.
