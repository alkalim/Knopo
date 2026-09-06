#!/bin/zsh
# Extracts every localizable string from the Swift sources and compares it with
# the checked-in baseline, so a new or reworded literal can't slip in unnoticed.
#
#   ./scripts/l10n-extract.sh                 check; non-zero exit on any drift
#   ./scripts/l10n-extract.sh --update        accept the current strings as the baseline
#   ./scripts/l10n-extract.sh --template LANG start a translation (see Localization/README.md)
#
# The extractor is the Swift compiler itself (`-emit-localized-strings`), which
# ships with the Command Line Tools — unlike `xcstringstool` and `genstrings`.
# It sees SwiftUI literals and `String(localized:)` alike, renders `\(n)` as
# `%lld`, and skips `Text(verbatim:)` and `Text(someString)` — so a literal that
# stops being localizable shows up here as a *removed* key.
#
# Note the full rebuild: SwiftPM emits .stringsdata only for files it actually
# compiles, so re-using a warm build directory would emit nothing at all and the
# comparison would pass vacuously.
set -e
cd "$(dirname "$0")/.."

SCRATCH="build/l10n"
DATA="build/l10n-keys"
BASE="Localization/keys.txt"

# Starting a translation needs no build — the baseline already lists every key.
if [[ "${1:-}" == "--template" ]]; then
  [[ -n "${2:-}" ]] || { echo "usage: $0 --template <language>   e.g. zh-Hans" >&2; exit 1 }
  LANG_TAG="$2" BASE="$BASE" python3 - <<'PY'
import os, plistlib, shutil, sys

lang, base = os.environ["LANG_TAG"], os.environ["BASE"]
out = f"Localization/{lang}.lproj"
if os.path.exists(out):
    sys.exit(f"error: {out} already exists; edit it rather than regenerating it")
os.makedirs(out)

keys, table, skip = {}, "Localizable", False
for line in open(base).read().splitlines():
    if not line or line.startswith("#"):
        continue
    if line.startswith("[") and line.endswith("]"):
        name = line[1:-1]
        # The ":plurals" sections repeat keys already listed above.
        skip = name.endswith(":plurals")
        table = name[:-len(":plurals")] if skip else name
    elif not skip:
        key, _, note = line.partition("\t")
        keys.setdefault(table, []).append((key, note))

for table, table_keys in keys.items():
    src_dict = f"Localization/en.lproj/{table}.stringsdict"
    plural = set(plistlib.load(open(src_dict, "rb"))) if os.path.exists(src_dict) else set()
    if plural:
        # Copied whole, comments and all: the translator edits the categories in
        # place and deletes the ones their language does not use.
        shutil.copy(src_dict, f"{out}/{table}.stringsdict")
    path = f"{out}/{table}.strings"
    written = 0
    with open(path, "w") as f:
        f.write(f"/* {lang} - right-hand sides are English; replace them. */\n")
        f.write("/* Delete a line you have not translated: it falls back to English. */\n")
        for key, note in table_keys:
            if key in plural:
                continue
            escaped = key.replace("\\", "\\\\").replace('"', '\\"')
            f.write(f"\n/* {note} */\n" if note else "\n")
            f.write(f'"{escaped}" = "{escaped}";\n')
            written += 1
    print(f"wrote {path} ({written} strings)")
    if plural:
        print(f"wrote {out}/{table}.stringsdict ({len(plural)} plural entries)")
print(f"\nNext: translate the right-hand sides, then ./scripts/test.sh and "
      f"./scripts/l10n-extract.sh")
PY
  exit 0
fi

rm -rf "$SCRATCH" "$DATA"
mkdir -p "$DATA"
echo "Extracting (full rebuild)…"
swift build --scratch-path "$SCRATCH" \
  -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc "$DATA" >/dev/null

emitted=(${DATA}/*.stringsdata(N))
if (( ${#emitted} == 0 )); then
  echo "error: no .stringsdata emitted — nothing was checked" >&2
  exit 1
fi

MODE="${1:-check}" DATA="$DATA" BASE="$BASE" python3 - <<'PY'
import collections, glob, json, os, plistlib, subprocess, sys

mode, data, base = os.environ["MODE"], os.environ["DATA"], os.environ["BASE"]

# Strings are addressed by (table, key): a table is how two identical English
# words get two translations (see BlockRenderer.ContentWeight.title).
where = collections.defaultdict(list)
comments = collections.defaultdict(set)
for path in glob.glob(f"{data}/*.stringsdata"):
    blob = json.load(open(path))
    src = os.path.relpath(blob.get("source", "?"), os.getcwd())
    for table, entries in (blob.get("tables") or {}).items():
        for e in entries:
            key = e["key"]
            if "\n" in key or "\t" in key:
                sys.exit(f"error: baseline format can't hold this key: {key!r}")
            where[(table, key)].append(f"{src}:{e['location']['startingLine']}")
            if e.get("comment"):
                comments[(table, key)].add(e["comment"])

found = sorted(where)
tables = sorted({t for t, _ in found})
print(f"{len(found)} distinct keys at {sum(map(len, where.values()))} call sites "
      f"in {len(tables)} table(s): {', '.join(tables)}")

# A shared key gets one entry in its .strings file, so two call sites with
# different comments would hand the translator contradictory guidance.
conflicts = {k: v for k, v in comments.items() if len(v) > 1}
for (table, key), texts in sorted(conflicts.items()):
    print(f"  conflicting comments for [{table}] {key!r} ({', '.join(where[(table, key)])}):")
    for c in sorted(texts):
        print(f"      {c!r}")
if conflicts:
    sys.exit("\nsame key, different comments — pick one per key, or split the tables")

def english_plurals(table):
    path = f"Localization/en.lproj/{table}.stringsdict"
    return set(plistlib.load(open(path, "rb"))) if os.path.exists(path) else set()


def render():
    out = [
        "# Every localizable string in the app, grouped by .strings table and",
        "# sorted. Generated by scripts/l10n-extract.sh --update. Keys are the",
        "# English text, so this file is also the translator's source list.",
        "# A key may be followed by a tab and its source comment, which",
        "# --template passes on to the translator.",
    ]
    for table in tables:
        out.append(f"[{table}]")
        for t, key in found:
            if t != table:
                continue
            note = next(iter(comments.get((t, key), ())), "")
            out.append(f"{key}\t{note}" if note else key)
        # Which keys carry plural rules is a judgement, not something the
        # compiler can tell us - "%lld of %lld" counts nothing. Record English's
        # answer so losing an entry later shows up as drift.
        entries = english_plurals(table)
        if entries:
            out.append(f"[{table}:plurals]")
            out += sorted(entries)
    return "\n".join(out) + "\n"

if mode == "--update":
    open(base, "w").write(render())
    print(f"wrote {base}")
    # Fall through: --update accepts new keys, it does not excuse a .lproj that
    # no longer matches them.

if not os.path.exists(base):
    sys.exit(f"error: {base} is missing; run with --update to create it")

old, required, table, section = [], collections.defaultdict(set), "Localizable", "keys"
for line in open(base).read().splitlines():
    if not line or line.startswith("#"):
        continue
    if line.startswith("[") and line.endswith("]"):
        name = line[1:-1]
        table, section = (name[:-len(":plurals")], "plurals") if name.endswith(":plurals") \
            else (name, "keys")
    elif section == "plurals":
        required[table].add(line)
    else:
        old.append((table, line.split("\t", 1)[0]))

if mode != "--update":
    added = [k for k in found if k not in set(old)]
    removed = [k for k in old if k not in set(found)]
    for table, key in added:
        print(f"  + [{table}] {key!r}   ({', '.join(where[(table, key)])})")
    for table, key in removed:
        print(f"  - [{table}] {key!r}")
    if added or removed:
        sys.exit("\nlocalizable strings drifted from the baseline; "
                 "re-run with --update once the change is intended")
    print("in sync with the baseline")

# Every .lproj is checked against the keys the compiler actually emits.
#
#   en.lproj is the reference and must be complete: a %lld key with no
#   .stringsdict entry degrades to the *formatted* key ("1 blocks"), which is
#   wrong English.
#
#   A translation may be partial — a missing key falls back to the English key
#   by design — but it may not carry a key that matches nothing. Those are
#   typos, and a typo'd key silently never appears.
def read_strings(path):
    """`.strings` is an old-style plist, which plistlib cannot read; plutil can."""
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"error: {path} is malformed\n{out.stderr.strip()}")
    return set(json.loads(out.stdout or "{}"))

problems = False
for lproj in sorted(glob.glob("Localization/*.lproj")):
    lang = os.path.basename(lproj)[: -len(".lproj")]
    reference = lang == "en"
    for table in tables:
        table_keys = {k for t, k in found if t == table}
        translated, plurals = set(), set()
        if os.path.exists(f"{lproj}/{table}.stringsdict"):
            plurals = set(plistlib.load(open(f"{lproj}/{table}.stringsdict", "rb")))
        if os.path.exists(f"{lproj}/{table}.strings"):
            translated = read_strings(f"{lproj}/{table}.strings")
        both = translated & plurals
        for k in sorted(both):
            print(f"  {lproj}/{table}: {k!r} is in both .strings and .stringsdict — "
                  f"the .strings entry would shadow the plural rules")
        known = translated | plurals
        # `continue` only for a language that has not started this table. The
        # reference is always checked: an emptied en .stringsdict would
        # otherwise pass, and every count would render as "1 blocks".
        if not known and not reference:
            continue

        orphans = sorted(known - table_keys)
        for k in orphans:
            print(f"  {lproj}/{table}: no such key {k!r} — a typo never reaches the UI")

        missing_plurals = sorted(required[table] - plurals)
        for k in missing_plurals:
            note = " - English would read \"1 blocks\"" if reference \
                else " - reads as English until it is added"
            print(f"  {lproj}/{table}: no plural entry for {k!r}{note}")

        if reference:
            # A new counting string is a nudge, not a failure: only a person can
            # say whether its number needs plural rules.
            for k in sorted({k for k in table_keys if "%lld" in k} - required[table]):
                print(f"  note: {k!r} has a count but no plural rules - add them to "
                      f"{lproj}/{table}.stringsdict if the wording changes with the number")

        if orphans or both or (reference and missing_plurals):
            problems = True
        elif reference:
            if required[table]:
                print(f"{len(plurals)} plural entries in {lproj}/{table}.stringsdict all match")
        else:
            done = len(known & table_keys)
            print(f"{lproj}/{table}: {done}/{len(table_keys)} translated, all keys valid")

if problems:
    sys.exit("\na .lproj is out of step with the source keys")
PY
