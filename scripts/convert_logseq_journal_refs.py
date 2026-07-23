#!/usr/bin/env python3
"""Convert Logseq journal page references to Knopo's canonical ISO form.

Logseq normally stores journal files with names such as ``2026_07_05.md`` but
uses the configured journal page title in Markdown references, for example
``[[Jul 5th, 2026]]``. Knopo uses ``[[2026-07-05]]`` as the page name. This
script changes the references; it never renames journal files.

The graph's ``logseq/config.edn`` supplies ``:journal/page-title-format``,
``:pages-directory``, and ``:journals-directory``. Missing settings use
Logseq's defaults: ``MMM do, yyyy``, ``pages``, and ``journals``.

Supported date tokens:

    yyyy
    M, MM, MMM, MMMM
    d, dd, do
    E, EE, EEE, EEEE

English month and weekday names are supported. Punctuation and whitespace are
literal. Alphabetic literal text must be enclosed in single quotes; two single
quotes represent one literal apostrophe.

Only semantic page references and page embeds are changed. References inside
fenced or inline code, escaped references, ``#[[...]]`` tags, Markdown links
and images, queries, math, and bare URLs are left untouched.

The default is a dry run. Use ``--write`` only after reviewing its report:

    scripts/convert_logseq_journal_refs.py /path/to/graph
    scripts/convert_logseq_journal_refs.py /path/to/graph --write

Writes are staged and atomically replace each changed file. File mode bits and
all bytes outside converted references, including line endings, are preserved.
Atomic replacement does not preserve ownership, ACLs, or extended attributes.
No backup files are created, so close applications that may edit the graph
concurrently and keep a filesystem backup or version-control checkpoint.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Pattern, Sequence, Set, Tuple


DEFAULT_PAGE_TITLE_FORMAT = "MMM do, yyyy"
DEFAULT_PAGES_DIRECTORY = "pages"
DEFAULT_JOURNALS_DIRECTORY = "journals"
MARKDOWN_SUFFIXES = {".md", ".markdown"}

SHORT_MONTHS = (
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
)
LONG_MONTHS = (
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
)
SHORT_WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
LONG_WEEKDAYS = (
    "Monday", "Tuesday", "Wednesday", "Thursday",
    "Friday", "Saturday", "Sunday",
)

DATE_TOKENS = (
    "yyyy", "MMMM", "MMM", "MM", "M",
    "do", "dd", "d",
    "EEEE", "EEE", "EE", "E",
)

FENCE_OPEN_RE = re.compile(
    r"^[ \t]*(?:[-*+][ \t]+)?(?P<marker>`{3,}|~{3,})"
)
NEWLINE_RE = re.compile(r"\r\n|\r|\n")
EMBED_PAGE_RE = re.compile(
    r"^\s*embed\s+(?P<ref>\[\[(?P<name>[^\[\]\r\n]+)\]\])\s*$",
    re.IGNORECASE,
)


class ConversionError(Exception):
    """A user-facing validation or conversion error."""


@dataclass(frozen=True)
class EDNToken:
    kind: str
    value: str


@dataclass(frozen=True)
class Replacement:
    start: int
    end: int
    line: int
    old: str
    new: str


@dataclass(frozen=True)
class FileSnapshot:
    device: int
    inode: int
    size: int
    mtime_ns: int
    mode: int


@dataclass
class FileChange:
    path: Path
    relative_path: Path
    original: bytes
    updated: bytes
    replacements: List[Replacement]
    snapshot: FileSnapshot


class DateTitleParser:
    """Compile and parse the supported subset of Logseq/date-fns formats."""

    def __init__(self, title_format: str) -> None:
        self.month_token: Optional[str] = None
        self.day_token: Optional[str] = None
        self.weekday_token: Optional[str] = None
        self.pattern = self._compile(title_format)

    def _compile(self, title_format: str) -> Pattern[str]:
        if not title_format:
            raise ConversionError("journal page title format is empty")

        pieces: List[str] = []
        seen: Set[str] = set()
        index = 0

        while index < len(title_format):
            char = title_format[index]
            if char == "'":
                literal, index = self._quoted_literal(title_format, index)
                pieces.append(re.escape(literal))
                continue

            token = next(
                (candidate for candidate in DATE_TOKENS
                 if title_format.startswith(candidate, index)),
                None,
            )
            if token is not None:
                field = self._field_for_token(token)
                if field in seen:
                    raise ConversionError(
                        f"journal page title format repeats the {field} field"
                    )
                seen.add(field)
                pieces.append(self._pattern_for_token(token))
                index += len(token)
                continue

            if char.isalpha():
                raise ConversionError(
                    f"unsupported date token beginning with {char!r} "
                    f"at position {index + 1}"
                )

            pieces.append(re.escape(char))
            index += 1

        missing = {"year", "month", "day"} - seen
        if missing:
            fields = ", ".join(sorted(missing))
            raise ConversionError(
                f"journal page title format is missing required field(s): {fields}"
            )

        return re.compile(r"^" + "".join(pieces) + r"$", re.IGNORECASE)

    @staticmethod
    def _quoted_literal(value: str, start: int) -> Tuple[str, int]:
        if start + 1 < len(value) and value[start + 1] == "'":
            return "'", start + 2

        result: List[str] = []
        index = start + 1
        while index < len(value):
            if value[index] != "'":
                result.append(value[index])
                index += 1
                continue
            if index + 1 < len(value) and value[index + 1] == "'":
                result.append("'")
                index += 2
                continue
            return "".join(result), index + 1
        raise ConversionError(
            f"unterminated quoted literal at position {start + 1}"
        )

    @staticmethod
    def _field_for_token(token: str) -> str:
        if token == "yyyy":
            return "year"
        if token.startswith("M"):
            return "month"
        if token.startswith("d"):
            return "day"
        return "weekday"

    def _pattern_for_token(self, token: str) -> str:
        if token == "yyyy":
            return r"(?P<year>[0-9]{4})"
        if token == "M":
            self.month_token = token
            return r"(?P<month>(?:[1-9]|1[0-2]))"
        if token == "MM":
            self.month_token = token
            return r"(?P<month>(?:0[1-9]|1[0-2]))"
        if token == "MMM":
            self.month_token = token
            return r"(?P<month>" + "|".join(SHORT_MONTHS) + r")"
        if token == "MMMM":
            self.month_token = token
            return r"(?P<month>" + "|".join(LONG_MONTHS) + r")"
        if token == "d":
            self.day_token = token
            return r"(?P<day>(?:[1-9]|[12][0-9]|3[01]))"
        if token == "dd":
            self.day_token = token
            return r"(?P<day>(?:0[1-9]|[12][0-9]|3[01]))"
        if token == "do":
            self.day_token = token
            return (
                r"(?P<day>(?:[1-9]|[12][0-9]|3[01]))"
                r"(?P<ordinal>st|nd|rd|th)"
            )
        if token in {"E", "EE", "EEE"}:
            self.weekday_token = token
            return r"(?P<weekday>" + "|".join(SHORT_WEEKDAYS) + r")"
        if token == "EEEE":
            self.weekday_token = token
            return r"(?P<weekday>" + "|".join(LONG_WEEKDAYS) + r")"
        raise AssertionError(f"unhandled date token: {token}")

    def parse(self, title: str) -> Optional[dt.date]:
        match = self.pattern.fullmatch(title)
        if match is None:
            return None

        year = int(match.group("year"))
        month_value = match.group("month")
        if self.month_token in {"M", "MM"}:
            month = int(month_value)
        elif self.month_token == "MMM":
            month = _casefold_index(SHORT_MONTHS, month_value) + 1
        else:
            month = _casefold_index(LONG_MONTHS, month_value) + 1
        day = int(match.group("day"))

        try:
            parsed = dt.date(year, month, day)
        except ValueError:
            return None

        if self.day_token == "do":
            if match.group("ordinal").casefold() != ordinal_suffix(day):
                return None

        weekday_value = match.groupdict().get("weekday")
        if weekday_value is not None:
            names = (
                LONG_WEEKDAYS
                if self.weekday_token == "EEEE"
                else SHORT_WEEKDAYS
            )
            if weekday_value.casefold() != names[parsed.weekday()].casefold():
                return None

        return parsed


def _casefold_index(values: Sequence[str], wanted: str) -> int:
    folded = wanted.casefold()
    for index, value in enumerate(values):
        if value.casefold() == folded:
            return index
    raise AssertionError(f"regular expression accepted unknown value: {wanted}")


def ordinal_suffix(day: int) -> str:
    if 11 <= day % 100 <= 13:
        return "th"
    return {1: "st", 2: "nd", 3: "rd"}.get(day % 10, "th")


def tokenize_edn(text: str, source: Path) -> List[EDNToken]:
    """Tokenize enough EDN to safely read string-valued Logseq settings."""
    tokens: List[EDNToken] = []
    delimiters = set("{}[]()")
    index = 0

    while index < len(text):
        char = text[index]
        if char.isspace() or char == ",":
            index += 1
            continue
        if char == ";":
            newline = text.find("\n", index + 1)
            index = len(text) if newline == -1 else newline + 1
            continue
        if char in delimiters:
            tokens.append(EDNToken("delimiter", char))
            index += 1
            continue
        if char == '"':
            value, index = parse_edn_string(text, index, source)
            tokens.append(EDNToken("string", value))
            continue

        start = index
        while (
            index < len(text)
            and not text[index].isspace()
            and text[index] not in delimiters
            and text[index] not in {",", ";"}
        ):
            index += 1
        tokens.append(EDNToken("atom", text[start:index]))

    return tokens


def parse_edn_string(text: str, start: int, source: Path) -> Tuple[str, int]:
    escapes = {
        '"': '"',
        "\\": "\\",
        "/": "/",
        "b": "\b",
        "f": "\f",
        "n": "\n",
        "r": "\r",
        "t": "\t",
    }
    result: List[str] = []
    index = start + 1

    while index < len(text):
        char = text[index]
        if char == '"':
            return "".join(result), index + 1
        if char != "\\":
            result.append(char)
            index += 1
            continue
        if index + 1 >= len(text):
            break
        escaped = text[index + 1]
        if escaped == "u":
            raw = text[index + 2:index + 6]
            if len(raw) != 4 or any(c not in "0123456789abcdefABCDEF" for c in raw):
                raise ConversionError(
                    f"{source}: invalid Unicode escape in EDN string"
                )
            result.append(chr(int(raw, 16)))
            index += 6
            continue
        if escaped not in escapes:
            raise ConversionError(
                f"{source}: unsupported EDN string escape \\{escaped}"
            )
        result.append(escapes[escaped])
        index += 2

    raise ConversionError(f"{source}: unterminated EDN string")


def read_config(graph: Path) -> Dict[str, Optional[str]]:
    config_path = graph / "logseq" / "config.edn"
    defaults: Dict[str, Optional[str]] = {
        ":journal/page-title-format": DEFAULT_PAGE_TITLE_FORMAT,
        ":pages-directory": DEFAULT_PAGES_DIRECTORY,
        ":journals-directory": DEFAULT_JOURNALS_DIRECTORY,
    }
    if not config_path.exists():
        return defaults
    if not config_path.is_file():
        raise ConversionError(f"{config_path}: expected a regular file")

    try:
        text = config_path.read_bytes().decode("utf-8")
    except UnicodeDecodeError as error:
        raise ConversionError(f"{config_path}: config is not valid UTF-8") from error
    except OSError as error:
        raise ConversionError(f"{config_path}: cannot read config: {error}") from error

    tokens = tokenize_edn(text, config_path)
    result = dict(defaults)
    for key in defaults:
        values: List[Optional[str]] = []
        for index, token in enumerate(tokens):
            if token.kind != "atom" or token.value != key:
                continue
            if index + 1 >= len(tokens):
                raise ConversionError(f"{config_path}: {key} has no value")
            value_token = tokens[index + 1]
            if value_token.kind == "string":
                values.append(value_token.value)
            elif value_token.kind == "atom" and value_token.value == "nil":
                values.append(None)
            else:
                raise ConversionError(
                    f"{config_path}: {key} must be a string or nil"
                )
        non_null_values = [value for value in values if value is not None]
        if len(set(non_null_values)) > 1:
            raise ConversionError(
                f"{config_path}: {key} is configured more than once"
            )
        if non_null_values:
            result[key] = non_null_values[-1]

    return result


def configured_directory(graph: Path, value: Optional[str], default: str) -> Path:
    relative = value if value is not None else default
    if not relative:
        raise ConversionError("configured graph directory is empty")
    candidate = Path(relative)
    if candidate.is_absolute():
        raise ConversionError(
            f"configured graph directory must be relative: {relative!r}"
        )

    resolved = (graph / candidate).resolve()
    try:
        resolved.relative_to(graph)
    except ValueError as error:
        raise ConversionError(
            f"configured graph directory escapes the graph: {relative!r}"
        ) from error
    if resolved.exists() and not resolved.is_dir():
        raise ConversionError(f"configured graph directory is not a directory: {resolved}")
    return resolved


def markdown_files(graph: Path, roots: Iterable[Path]) -> List[Path]:
    found: Dict[Path, Path] = {}
    for root in roots:
        if not root.exists():
            continue
        for directory, subdirectories, filenames in os.walk(root, followlinks=False):
            directory_path = Path(directory)
            subdirectories.sort()
            filenames.sort()
            for filename in filenames:
                path = directory_path / filename
                if path.suffix.casefold() not in MARKDOWN_SUFFIXES:
                    continue
                if path.is_symlink():
                    raise ConversionError(
                        f"refusing to process symlinked Markdown file: {path}"
                    )
                try:
                    resolved = path.resolve(strict=True)
                    resolved.relative_to(graph)
                except (OSError, ValueError) as error:
                    raise ConversionError(
                        f"Markdown file resolves outside the graph: {path}"
                    ) from error
                found[resolved] = resolved
    return sorted(found.values(), key=lambda path: path.relative_to(graph).as_posix())


def snapshot_for(stat_result: os.stat_result) -> FileSnapshot:
    return FileSnapshot(
        device=stat_result.st_dev,
        inode=stat_result.st_ino,
        size=stat_result.st_size,
        mtime_ns=stat_result.st_mtime_ns,
        mode=stat_result.st_mode,
    )


def read_change(
    graph: Path,
    path: Path,
    date_parser: DateTitleParser,
) -> Optional[FileChange]:
    try:
        with path.open("rb") as handle:
            stat_result = os.fstat(handle.fileno())
            original = handle.read()
    except OSError as error:
        raise ConversionError(f"{path}: cannot read file: {error}") from error

    try:
        text = original.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ConversionError(f"{path}: Markdown is not valid UTF-8") from error

    updated_text, replacements = convert_text(text, date_parser)
    if not replacements:
        return None
    return FileChange(
        path=path,
        relative_path=path.relative_to(graph),
        original=original,
        updated=updated_text.encode("utf-8"),
        replacements=replacements,
        snapshot=snapshot_for(stat_result),
    )


def convert_text(
    text: str,
    date_parser: DateTitleParser,
) -> Tuple[str, List[Replacement]]:
    replacements: List[Replacement] = []
    active_fence: Optional[Tuple[str, int]] = None
    offset = 0

    for line_number, raw_line in enumerate(physical_lines(text), start=1):
        line = raw_line
        if line.endswith("\r\n"):
            body = line[:-2]
        elif line.endswith("\n") or line.endswith("\r"):
            body = line[:-1]
        else:
            body = line

        if active_fence is not None:
            marker_char, minimum_length = active_fence
            if is_fence_close(body, marker_char, minimum_length):
                active_fence = None
        else:
            opening = FENCE_OPEN_RE.match(body)
            if opening is not None:
                marker = opening.group("marker")
                active_fence = (marker[0], len(marker))
            else:
                replacements.extend(
                    inline_replacements(
                        body,
                        absolute_offset=offset,
                        line_number=line_number,
                        date_parser=date_parser,
                    )
                )
        offset += len(raw_line)

    if not replacements:
        return text, []

    pieces: List[str] = []
    cursor = 0
    for replacement in replacements:
        pieces.append(text[cursor:replacement.start])
        pieces.append(replacement.new)
        cursor = replacement.end
    pieces.append(text[cursor:])
    return "".join(pieces), replacements


def physical_lines(text: str) -> Iterable[str]:
    """Yield lines split only on Markdown's CRLF, CR, and LF terminators."""
    start = 0
    for newline in NEWLINE_RE.finditer(text):
        yield text[start:newline.end()]
        start = newline.end()
    if start < len(text):
        yield text[start:]


def is_fence_close(line: str, marker_char: str, minimum_length: int) -> bool:
    stripped = line.lstrip(" \t")
    if len(stripped) >= 2 and stripped[0] in "-*+" and stripped[1].isspace():
        stripped = stripped[2:].lstrip(" \t")
    stripped = stripped.rstrip(" \t")
    if len(stripped) < minimum_length:
        return False
    return all(char == marker_char for char in stripped)


def inline_replacements(
    line: str,
    absolute_offset: int,
    line_number: int,
    date_parser: DateTitleParser,
) -> List[Replacement]:
    replacements: List[Replacement] = []
    index = 0

    while index < len(line):
        char = line[index]

        if char == "\\" and index + 1 < len(line):
            if line[index + 1] in "#[({`*~=$":
                index += 2
                continue

        if char == "`":
            run_length = repeated_character_count(line, index, "`")
            closing = matching_backtick_run(line, index + run_length, run_length)
            if closing is not None:
                index = closing + run_length
            else:
                index += run_length
            continue

        if char == "$":
            closing = line.find("$", index + 1)
            if closing > index + 1:
                index = closing + 1
                continue

        if char == "!" and index + 1 < len(line) and line[index + 1] == "[":
            image_end = markdown_link_end(line, index + 1)
            if image_end is not None:
                index = image_end
                continue

        if char == "[":
            link_end = markdown_link_end(line, index)
            if link_end is not None:
                index = link_end
                continue
            if line.startswith("[[", index):
                reference_end = page_reference_end(line, index)
                if reference_end is not None:
                    if index == 0 or line[index - 1] != "#":
                        add_replacement(
                            replacements,
                            line,
                            index,
                            reference_end,
                            absolute_offset,
                            line_number,
                            date_parser,
                        )
                    index = reference_end
                    continue

        if char == "#" and line.startswith("#[[", index):
            tag_end = page_reference_end(line, index + 1)
            if tag_end is not None:
                tag_name = line[index + 3:tag_end - 2].strip()
                if tag_name and "[" not in tag_name and "]" not in tag_name:
                    index = tag_end
                    continue

        if char == "{" and line.startswith("{{", index):
            macro_end = line.find("}}", index + 2)
            if macro_end != -1:
                inner_start = index + 2
                inner = line[inner_start:macro_end]
                embed = EMBED_PAGE_RE.fullmatch(inner)
                if embed is not None:
                    ref_start = inner_start + embed.start("ref")
                    ref_end = inner_start + embed.end("ref")
                    add_replacement(
                        replacements,
                        line,
                        ref_start,
                        ref_end,
                        absolute_offset,
                        line_number,
                        date_parser,
                    )
                index = macro_end + 2
                continue

        if char in {"h", "H"} and autolink_boundary(line, index):
            lowered = line[index:].lower()
            if lowered.startswith("https://") or lowered.startswith("http://"):
                end = index
                while end < len(line) and not line[end].isspace() and line[end] not in "<>`":
                    end += 1
                index = end
                continue

        index += 1

    return replacements


def repeated_character_count(value: str, start: int, character: str) -> int:
    end = start
    while end < len(value) and value[end] == character:
        end += 1
    return end - start


def matching_backtick_run(value: str, start: int, length: int) -> Optional[int]:
    index = start
    marker = "`" * length
    while True:
        found = value.find(marker, index)
        if found == -1:
            return None
        before_matches = found > 0 and value[found - 1] == "`"
        after = found + length
        after_matches = after < len(value) and value[after] == "`"
        if not before_matches and not after_matches:
            return found
        index = found + length


def page_reference_end(line: str, start: int) -> Optional[int]:
    closing = line.find("]]", start + 2)
    if closing == -1:
        return None
    name = line[start + 2:closing]
    if not name or "[" in name or "]" in name:
        return None
    return closing + 2


def markdown_link_end(line: str, bracket_start: int) -> Optional[int]:
    depth = 0
    index = bracket_start + 1
    label_end: Optional[int] = None
    while index < len(line):
        if line[index] == "\\" and index + 1 < len(line):
            index += 2
            continue
        if line[index] == "[":
            depth += 1
        elif line[index] == "]":
            if depth == 0:
                label_end = index
                break
            depth -= 1
        index += 1

    if (
        label_end is None
        or label_end + 1 >= len(line)
        or line[label_end + 1] != "("
    ):
        return None

    parenthesis_depth = 0
    index = label_end + 2
    while index < len(line):
        if line[index] == "\\" and index + 1 < len(line):
            index += 2
            continue
        if line[index] == "(":
            parenthesis_depth += 1
        elif line[index] == ")":
            if parenthesis_depth == 0:
                return index + 1
            parenthesis_depth -= 1
        index += 1
    return None


def autolink_boundary(line: str, index: int) -> bool:
    return (
        index == 0
        or line[index - 1].isspace()
        or line[index - 1] in "([{<'\""
    )


def add_replacement(
    replacements: List[Replacement],
    line: str,
    start: int,
    end: int,
    absolute_offset: int,
    line_number: int,
    date_parser: DateTitleParser,
) -> None:
    title = line[start + 2:end - 2]
    parsed = date_parser.parse(title)
    if parsed is None:
        return

    old = line[start:end]
    new = f"[[{parsed.year:04d}-{parsed.month:02d}-{parsed.day:02d}]]"
    if old == new:
        return
    replacements.append(
        Replacement(
            start=absolute_offset + start,
            end=absolute_offset + end,
            line=line_number,
            old=old,
            new=new,
        )
    )


def ensure_unchanged(change: FileChange) -> None:
    try:
        if change.path.is_symlink():
            raise ConversionError(
                f"{change.path}: file became a symlink after it was scanned"
            )
        with change.path.open("rb") as handle:
            current = os.fstat(handle.fileno())
            current_bytes = handle.read()
    except OSError as error:
        raise ConversionError(
            f"{change.path}: cannot verify file before writing: {error}"
        ) from error
    if (
        snapshot_for(current) != change.snapshot
        or current_bytes != change.original
    ):
        raise ConversionError(
            f"{change.path}: file changed after it was scanned; "
            "refusing to overwrite it"
        )


def write_changes(changes: Sequence[FileChange]) -> None:
    staged: List[Tuple[FileChange, Path]] = []
    try:
        for change in changes:
            ensure_unchanged(change)

        for change in changes:
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=f".{change.path.name}.",
                suffix=".tmp",
                dir=change.path.parent,
            )
            temporary = Path(temporary_name)
            try:
                os.fchmod(descriptor, stat.S_IMODE(change.snapshot.mode))
                with os.fdopen(descriptor, "wb") as handle:
                    descriptor = -1
                    handle.write(change.updated)
                    handle.flush()
                    os.fsync(handle.fileno())
            except Exception:
                if descriptor != -1:
                    os.close(descriptor)
                temporary.unlink(missing_ok=True)
                raise
            staged.append((change, temporary))

        for index, (change, temporary) in enumerate(staged):
            try:
                ensure_unchanged(change)
                os.replace(temporary, change.path)
            except (ConversionError, OSError) as error:
                for _, remaining in staged[index:]:
                    remaining.unlink(missing_ok=True)
                detail = (
                    "some earlier files may already have been updated"
                    if index > 0
                    else "no files were updated"
                )
                raise ConversionError(
                    f"{error} ({detail})"
                ) from error
    except ConversionError:
        for _, temporary in staged:
            temporary.unlink(missing_ok=True)
        raise
    except OSError as error:
        for _, temporary in staged:
            temporary.unlink(missing_ok=True)
        raise ConversionError(f"could not stage writes; no files were updated: {error}") from error


def print_report(
    changes: Sequence[FileChange],
    scanned_count: int,
    write: bool,
) -> None:
    for change in changes:
        noun = "replacement" if len(change.replacements) == 1 else "replacements"
        print(f"{change.relative_path.as_posix()} ({len(change.replacements)} {noun})")
        for replacement in change.replacements:
            print(
                f"  line {replacement.line}: "
                f"{replacement.old} -> {replacement.new}"
            )

    reference_count = sum(len(change.replacements) for change in changes)
    action = "changed" if write else "would change"
    scanned_noun = "file" if scanned_count == 1 else "files"
    file_noun = "file" if len(changes) == 1 else "files"
    ref_noun = "reference" if reference_count == 1 else "references"
    print(
        f"Summary: scanned {scanned_count} Markdown {scanned_noun}; "
        f"{len(changes)} {file_noun} {action}; "
        f"{reference_count} {ref_noun} {action}."
    )
    if not write and changes:
        print("Dry run only. Re-run with --write to apply these changes.")


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Convert file-based Logseq journal page references to "
            "Knopo's [[YYYY-MM-DD]] form. The default is a dry run."
        ),
        epilog=(
            "Examples:\n"
            "  %(prog)s ~/Documents/MyGraph\n"
            "  %(prog)s ~/Documents/MyGraph --write\n\n"
            "The journal title format and graph directories are read from "
            "logseq/config.edn. Run %(prog)s --help and see the module "
            "documentation at the top of the source for supported date tokens "
            "and safety details. Atomic writes preserve file mode bits, but "
            "not ownership, ACLs, or extended attributes."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "graph",
        type=Path,
        help="path to the root of a file-based Logseq graph",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="report changes without writing (the default)",
    )
    mode.add_argument(
        "--write",
        action="store_true",
        help="atomically update files after validating the entire graph",
    )
    return parser


def run(arguments: argparse.Namespace) -> None:
    try:
        graph = arguments.graph.expanduser().resolve(strict=True)
    except OSError as error:
        raise ConversionError(f"{arguments.graph}: graph does not exist") from error
    if not graph.is_dir():
        raise ConversionError(f"{graph}: graph path is not a directory")

    config = read_config(graph)
    title_format = config[":journal/page-title-format"]
    if title_format is None:
        title_format = DEFAULT_PAGE_TITLE_FORMAT
    try:
        date_parser = DateTitleParser(title_format)
    except ConversionError as error:
        raise ConversionError(
            f"unsupported :journal/page-title-format {title_format!r}: {error}. "
            "No files were written."
        ) from error

    pages = configured_directory(
        graph,
        config[":pages-directory"],
        DEFAULT_PAGES_DIRECTORY,
    )
    journals = configured_directory(
        graph,
        config[":journals-directory"],
        DEFAULT_JOURNALS_DIRECTORY,
    )
    files = markdown_files(graph, (pages, journals))

    changes: List[FileChange] = []
    for path in files:
        change = read_change(graph, path, date_parser)
        if change is not None:
            changes.append(change)

    if arguments.write and changes:
        write_changes(changes)
    print_report(changes, len(files), arguments.write)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argument_parser()
    arguments = parser.parse_args(argv)
    try:
        run(arguments)
    except ConversionError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
