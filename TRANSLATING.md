# Translating Mac Performance Monitor

Every language lives in one file:

```
Localizations/Localizable.xcstrings
```

That is an Apple **String Catalog**: a JSON document holding every key, the
English source text, and one entry per language. There are no per-language
folders to keep in sync, and adding a language does not touch any Swift code.

You do not need Xcode to translate. You do need it to build the app, because
the catalog is compiled by `xcstringstool`, which ships inside Xcode.

## Adding a language

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

3. Add your language to the picker in
   `Sources/MacPerfMonitor/Settings/AppLanguageManager.swift`: one `case` on
   `AppLanguage` with its native name, for example `case fr = "fr"` and
   `"Français"`. That is the only Swift change a translation needs.

4. Build, switch to your language in Settings, and click through the app:

   ```sh
   Scripts/run.sh
   ```

5. Check your work, then open a pull request:

   ```sh
   Scripts/check-localization.py
   ```

**Partial translations are welcome.** Any key you leave out falls back to
English, so you can start with the menu bar and settings and grow from there.

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
