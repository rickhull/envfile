# compat

`envfile/compat` is an envfile format targeting broad compatibility with
systemd's `EnvironmentFile` parser. The goal is to accept roughly 90% of what
systemd accepts — the common, well-behaved subset that appears in real
`EnvironmentFile=` inputs across production systems.

## Why compat exists

systemd is the dominant consumer of env files on Linux. It parses
`EnvironmentFile=` with its own rules, which differ from POSIX shell sourcing
in specific ways:

- Unquoted values may contain interior whitespace, which is preserved
- Both `#` and `;` start comment lines
- Double-quoted values recognize shell-style backslash escapes
- Backslash-newline is a line continuation
- Leading and trailing whitespace is stripped from keys and values

Neither `shell` (which rejects unquoted whitespace) nor `native` (which has no
quoting at all) can accept these files. `compat` fills that gap.

## What compat is not

`compat` does not try to be a shell. It does not expand `$VAR`, `${VAR}`, or
backtick subshells. It does not support `export` prefixes. It does not
implement systemd's `merge_env_file` variable expansion path.

It is a *subset* of systemd's parser, not a full reimplementation.

## Relationship to other formats

- **shell** optimizes for discipline — quoting rules, error diagnostics, safe
  shell sourcing
- **native** optimizes for fidelity — serialized `envp`, no interpretation
  layer
- **compat** optimizes for acceptance — meets systemd and friends where they
  are

## Format

An envfile is a UTF-8 text file. Each line is either blank, a comment, or an
assignment.

### Blank lines

A line is blank if it is empty or contains only whitespace (space, tab,
carriage return). Blank lines are ignored.

### Comments

A line whose first non-whitespace character is `#` or `;` is a comment.
Comments are ignored.

```text
# this is a comment
; this is also a comment
```

No inline comments. A `#` or `;` appearing after a key or value is not
special.

### Assignments

```text
KEY=VALUE
```

The line is split at the first `=` character. Everything before is the key;
everything after is the value.

### Key

A key must match `[A-Za-z_][A-Za-z0-9_]*`.

Keys must not have leading or trailing whitespace. Leading and trailing
whitespace around the key is silently stripped.

Keys may be uppercase, lowercase, or mixed case. The compat parser preserves
them as written.

### Value

The value is everything after the first `=`, after stripping leading
whitespace. An empty value is valid:

```text
KEY=
```

Trailing whitespace in unquoted values is silently stripped.

There are four value forms.

#### 1. Unquoted

```text
KEY=value
KEY=hello world
```

A bare string. Interior whitespace is preserved. Leading and trailing
whitespace is stripped.

Backslash escapes are recognized per POSIX shell unquoted text: `\<char>`
preserves the following character. `\<newline>` is a line continuation (the
backslash and newline are discarded).

```text
PATH=/usr/local/bin\:/usr/bin
```

#### 2. Single-quoted

```text
KEY='value'
```

Delimited by `'`. The content between the quotes is taken literally, with no
escaping or interpretation. The content must not contain `'`.

Single-quoted values may span multiple lines.

```text
MESSAGE='hello
world'
```

Leading and trailing whitespace outside the single quotes is discarded.

#### 3. Double-quoted

```text
KEY="value"
```

Delimited by `"`. Backslash escape sequences are recognized as in POSIX shell
double-quoted text:

- `\"` → `"`
- `\\` → `\`
- `` \` `` → `` ` ``
- `\$` → `$`
- `\<newline>` → line continuation (discarded)
- `\<any other>` → backslash and character are both preserved

Double-quoted values may span multiple lines.

Leading and trailing whitespace outside the double quotes is discarded.

#### 4. Line continuation

A backslash immediately followed by a newline is a line continuation in
unquoted values. The backslash and newline are discarded, and the next line is
appended to the value.

```text
COMMAND=hello \
world
```

Sets `COMMAND` to `hello world`.

### Constraint summary

| Condition | Result |
|---|---|
| No `=` in line | error |
| Leading whitespace before key | stripped |
| Trailing whitespace before `=` | stripped |
| Leading whitespace after `=` | stripped |
| Key not matching `[A-Za-z_][A-Za-z0-9_]*` | error |
| Key case | accepted |
| Unquoted value containing interior whitespace | accepted |
| Unquoted value with `\<newline>` | line continuation |
| Unquoted value with `\<other>` | backslash escape |
| Unterminated `'` | error |
| Unterminated `"` | error |
| Empty value (`KEY=`) | valid |
| Blank line | ignored |
| Line starting with `#` or `;` | ignored |
| Inline `#` or `;` after value | not special |
| UTF-8 encoding required | yes |
| NUL byte in file | error |

### Dollar sign is not special

`$`, backtick, and `${` are not special to the compat parser. They are literal
bytes in values. A consumer may interpret them differently — for example,
systemd's `environment.d` path expands `$VAR` against a provided environment —
but that is a processing concern, not a validation concern.

The compat validator's job is to accept structurally valid files. Whether and
how a consumer expands variables depends on the environment passed in, which is
outside the parser's scope.

## What is out of scope (the ~10% we don't target)

These features are intentionally excluded from compat's validation scope:

- **Variable expansion** (`$VAR`, `${VAR}`, `${x:-default}`) — the parser
  treats `$` as a literal byte; expansion requires a prior environment that is
  outside the validator's scope
- **Command substitution** (backtick or `$()`) — systemd does not support this
  in EnvironmentFile content
- **`export` prefix** on assignments — systemd rejects `export` as an invalid
  key
- **Environment=` inline assignments** (that's a different systemd directive)
- **Specifier expansion** (`%h`, `%u`, `%H`) — systemd expands these in the
  file path argument, not inside file content
- **Binary/non-UTF-8 content** — systemd requires valid UTF-8

## Examples

### Valid

```text
# service configuration
DATABASE_PATH=/data/app.db
GREETING=hello world
EMPTY=
JSON={"a":1}
PATH_LIKE=/usr/local/bin:/usr/bin
EQUALS=base64://abc=def==
HASH=#not_a_comment
DOLLAR=$HOME/bin
QUOTED_SINGLE='literal value'
QUOTED_DOUBLE="it's fine"
MULTILINE="line one
line two"
ESCAPED="path\\to\\file"
CONTINUATION=hello \
world
; semicolon comment
```

### Invalid

```text
=bar              # empty key
FOO BAR=baz       # space in key
123_BAD=oops      # key starts with digit
FOO               # missing =
```

## Status

Spec draft. No implementations yet.
