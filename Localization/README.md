# Translating Knopo

Knopo's interface is English by default and picks up any language you add here.

## Start

```sh
./scripts/l10n-extract.sh --template zh-Hans
```

That creates `Localization/zh-Hans.lproj/` holding every string, with the English
text on both sides of each line. Replace the right-hand sides.

Name the directory with the language tag macOS uses. The ones asked for most:

| Tag | Language |
| --- | --- |
| `zh-Hans` | Chinese, Simplified - 简体中文 |
| `zh-Hant` | Chinese, Traditional - 繁體中文 |
| `es` | Spanish - Español |
| `hi` | Hindi - हिन्दी |
| `pt-BR` | Portuguese, Brazil - Português |
| `ru` | Russian - Русский |
| `ja` | Japanese - 日本語 |
| `de` | German - Deutsch |
| `fr` | French - Français |
| `ko` | Korean - 한국어 |
| `it` | Italian - Italiano |

Any tag macOS accepts works, not just these. Drop the region unless it changes
the words (`pt-BR` and `pt-PT` differ enough to be worth splitting; `de-AT`
usually is not).

Simplified and Traditional Chinese are separate translations - neither falls
back to the other, so a Traditional user sees English until `zh-Hant` exists.

Right-to-left languages, such as Arabic, are not supported yet.

## The files

| File | What it holds |
| --- | --- |
| `Localizable.strings` | Almost everything: menus, buttons, alerts, labels. |
| `Localizable.stringsdict` | The five strings that count things, which need plural rules. |
| `FontWeight.strings` | Three words, kept apart on purpose - see below. |

`Localization/keys.txt` is the full list of source strings, regenerated from the
code. It is what the template is built from.

## Rules

**Never change the left-hand side.** It is the key the app looks up; a typo
there means your translation never appears. The check catches it.

**Leave `%` sequences alone** - `%@`, `%lld`, `%1$lld`, `%#@count@`. They are
placeholders the app fills in. Move one to where your language needs it, but
never translate or renumber it.

**A missing line falls back to English**, so partial translations are welcome.
Delete lines you have not done rather than leaving them English, so the progress
count means something.

**Near-duplicates are deliberate**, but for two different reasons. `Delete` and
`Delete…` differ because `…` means "opens a dialog" - that convention is the
same in every language, so keep it: 删除 and 删除…. `Find in Page` (menu, title
case) and `Find in page` (placeholder, sentence case) differ only because macOS
capitalizes menus and placeholders differently. A language without letter case
has nowhere to put that distinction, so both simply get the same text - in
Chinese, 在页面中查找 twice.

**`FontWeight.strings` exists because "Light" means two things** - the appearance
theme and the body font weight (German: *Hell* vs *Light*). The theme is in
`Localizable.strings`; the weight is here.

## Plurals

`Localizable.stringsdict` is a plist, one entry per counting string. English
needs `one` and `other`:

```xml
<key>one</key>
<string>%lld block</string>
<key>other</key>
<string>%lld blocks</string>
```

Your language may need fewer or more. **Delete the categories your language does
not use and add the ones it does.** The six names - `zero`, `one`, `two`, `few`,
`many`, `other` - come from CLDR, the locale database Unicode publishes and macOS
reads; it is also what decides at runtime which category a given number falls
into, so you cannot invent a seventh. CLDR lists
[the categories each language needs](https://cldr.unicode.org/index/cldr-spec/plural-rules).
`other` is always required: it is the fallback when nothing else matches.

Chinese needs only `other`. Russian needs four, chosen by the last digits:

| category | counts | "%lld blocks" |
| --- | --- | --- |
| `one` | 1, 21, 101 | 1 блок |
| `few` | 2, 3, 4, 22 | 2 блока |
| `many` | 0, 5-20, 25 | 5 блоков |
| `other` | fractions only | (copy `many`) |

French shows that a two-category language need not split where English does:

| category | counts | "%lld blocks" |
| --- | --- | --- |
| `one` | 0, 1 | 1 bloc |
| `other` | 2, 3, 4… | 2 blocs |

French puts zero in the singular - "0 bloc", not "0 blocs".

`zero` is a special case, separate from the rules above: it matches a literal 0
in any language. The delete-page message uses it to drop a sentence when nothing
breaks.

**Do not skip an entry here.** A missing ordinary string falls back to its key,
which is readable English. A missing *plural* falls back to the key's raw
format - `%lld blocks` renders as "7 blocks" - so that one line appears in
English inside an otherwise translated interface.

## Check your work

```sh
./scripts/test.sh            # rejects a malformed .strings or .stringsdict
./scripts/l10n-extract.sh    # reports progress and catches keys that match nothing
```

A syntax error in a `.strings` file breaks the **whole file**, not one line, so
run these before opening a PR. Common cause: a missing `;` at the end of a line,
or an unescaped `"` inside a value (write `\"`).

## See it running

```sh
./scripts/build-app.sh release
build/Knopo.app/Contents/MacOS/Knopo -AppleLanguages '(zh-Hans)'
```

That forces one language without changing your system settings. Look for text
that overflows its control - German and Finnish run long, and the Settings window
is a fixed size.

`swift run Knopo` will **not** show your translation: it runs the bare executable,
which has no bundle to read these files from. Build the app.
