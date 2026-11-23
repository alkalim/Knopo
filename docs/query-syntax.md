# Query syntax

Knopo queries display a live, read-only list of matching blocks or pages inside
an ordinary block. A query can filter tags, page references, task state, and
properties, then combine those filters with Boolean operators.

See the [user guide](features.md) for the surrounding concepts and
[Commands](commands.md) for `/query` and editing shortcuts.

## Create a query

Write an expression inside `{{query ...}}`:

```markdown
{{query #work TODO}}
```

The easiest way to start is `/query`, which inserts `{{query }}` and puts the
caret inside. While the block is focused you see and edit the source. Leave the
block to display its results.

Knopo supports two equivalent styles:

```markdown
{{query #urgent TODO [[Project Knopo]]}}
{{query (and #urgent TODO [[Project Knopo]])}}
```

The first is **shorthand**: multiple top-level filters are implicitly joined by
`and`. The second is **structured syntax**, which uses parenthesized expressions
for explicit and nested logic.

## Filter reference

| What to match | Shorthand | Structured form |
|---|---|---|
| Tag | `#urgent` | `(tag urgent)` |
| Multi-word tag | `#[[in progress]]` | `(tag "in progress")` |
| Link to a page | `[[Project Knopo]]` | `(page "Project Knopo")` |
| One task state | `TODO` or `DONE` | `(task TODO)` |
| Either task state | n/a | `(task TODO DONE)` |
| Property with an exact value | `status:: open` or `status::open` | `(property "status" "open")` |
| Property exists, any value | `status::` | `(property "status")` |

### Tags

`#work` matches blocks tagged `#work` and pages with `work` in their `tags::`
property above the outline. A page tag applies to the page as a whole. Tag
matching is case-insensitive.

```markdown
{{query #work}}
{{query #[[in progress]]}}
{{query (or #work #personal)}}
```

A tag filter matches a tag token, not plain text containing the same word.

### Page references

`[[Page Name]]` matches blocks that link to the page by its name or an alias.
You can use either name in the query. Page identity is case-insensitive.

```markdown
{{query [[Project Knopo]]}}
{{query (and [[Project Knopo]] TODO)}}
{{query (page "Project Knopo")}}
```

This is a **links-to** filter: it finds blocks containing the page reference. It
does not restrict results to blocks located on that page. Query criteria also do
not count as references themselves, so putting `[[Project Knopo]]` in a query
does not create a backlink to that page.

Block references are indexed for backlinks, but Knopo has no query filter for a
particular block reference.

### Task state

`TODO` and `DONE` match a task marker at the beginning of a block. The structured
`task` form accepts one or both states:

```markdown
{{query TODO}}
{{query (task TODO DONE)}}
{{query (and #work (not DONE))}}
```

`(not DONE)` includes both `TODO` blocks and blocks with no task marker. To ask
for unfinished tasks specifically, use `TODO` rather than `(not DONE)`.

### Properties

Properties use exact, case-sensitive key and value matching:

```markdown
{{query status:: open}}
{{query status::}}
{{query (property "status" "in progress")}}
{{query (property "status")}}
```

In shorthand, `key:: value` consumes one following bare or quoted value. Use the
structured form for multi-word values and whenever adjacent property filters
would be ambiguous:

```markdown
{{query (and (property "status" "in progress")
             (property "owner" "Alex"))}}
```

A block property is written on a continuation line after its block content:

```markdown
- Prepare the release
  status:: in progress
  owner:: Alex
```

That block matches `status:: "in progress"` and
`(property "owner" "Alex")`.

Unbulleted properties before the first block are **page properties**:

```markdown
type:: project
status:: active
- First note on the project
```

A property-only query can return the page itself, including a page that contains
only properties:

```markdown
{{query type:: project}}
{{query (and (property "type" "project")
             (property "status" "active"))}}
```

Page-level matches can combine tag and property filters with `and` or `or`.
For example, `{{query (and #work (property "status" "active"))}}` can find a
page with both `tags:: work` and `status:: active` above its outline. Knopo
tests each block against its own tags and properties. Expressions containing
a page reference, task, or `not` return only blocks.

## Boolean operators

Structured expressions use prefix operators:

| Form | Meaning |
|---|---|
| `(and A B ...)` | Every child expression must match. |
| `(or A B ...)` | At least one child expression must match. |
| `(not A)` | The child expression must not match. |

Operators may be nested:

```markdown
{{query (and #work (not DONE))}}

{{query (and (or #urgent #important)
             TODO)}}

{{query (or (and #work TODO)
            (and #personal TODO))}}
```

There are no infix operators or precedence rules. Write `(and A B)` rather than
`A and B`, and use parentheses to express every nested group. At the outermost
level, adjacent filters are the one exception: they imply `and`.

## Structured forms and quoting

Structured syntax is useful when a name or value contains spaces:

```markdown
{{query (tag "waiting for")}}
{{query (page "Long Project Name")}}
{{query (property "review-status" "needs changes")}}
```

Page and tag tokens can also be used as arguments:

```markdown
{{query (tag #[[waiting for]])}}
{{query (page [[Long Project Name]])}}
```

Quotes group a string; there is no escape syntax inside a quoted query string.
For straightforward tag and page filters, the native `#[[...]]` and `[[...]]`
forms are usually clearer.

An informal grammar for the supported language is:

```text
query       = expression { expression }       # adjacent expressions imply AND
expression  = tag | page-ref | task | property | compound
compound    = "(" (and | or) expression { expression } ")"
            | "(" not expression ")"
            | "(" tag string ")"
            | "(" page string ")"
            | "(" task (TODO | DONE) { TODO | DONE } ")"
            | "(" property string [string] ")"
```

Keywords such as `and`, `or`, `not`, `tag`, `page`, `task`, and `property` are
case-insensitive. Unknown bare words are not full-text terms; they make the query
invalid.

## More examples

Open tasks tagged with either `#work` or `#volunteer`:

```markdown
{{query (and TODO (or #work #volunteer))}}
```

Blocks that link to a project and are not done:

```markdown
{{query (and [[Project Knopo]] (not DONE))}}
```

Urgent blocks that do not link to the archive page:

```markdown
{{query (and #urgent (not [[Archive]]))}}
```

Blocks with an owner property, regardless of its value:

```markdown
{{query owner::}}
```

Blocks with either of two property values:

```markdown
{{query (or (property "status" "open")
            (property "status" "blocked"))}}
```

## Results and updates

Query results are grouped by source page. Journal pages sort newest first;
ordinary pages sort alphabetically, with blocks in document order. Results are
capped at 50, with a footer when more matches exist.

- Click a row to navigate to its source block.
- Click a result's `TODO`/`DONE` checkbox to update the source block.
- The query's own host block is always excluded.
- Results update when the graph index changes. A source block that no longer
  matches disappears on re-evaluation.
- Results are read-only apart from task checkboxes; edit other content at the
  source.

A malformed or empty query is shown literally instead of executing. Knopo does
not rewrite or discard it, so you can focus the block and repair the expression.

## Current limitations

Knopo does not yet support:

- arbitrary full-text terms
- filtering for a specific block reference
- restricting results to the current page or to the descendants of a block
- journal date ranges
- custom sorting, grouping, or limits
- displaying results as a table
- saving a query under a name and opening it directly from navigation

Use graph search (`⌘K`) for arbitrary text. Use queries when you need repeatable,
live combinations of indexed tags, page links, tasks, and properties.
