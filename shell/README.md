# shell

> **Note:** This format was renamed from `strict` to `shell` to reflect its
> shell-oriented design principle.

`envfile/shell` is the current, mature format in this repository.

This is the working entry point for shell tasks:

```sh
just impls
make all
just shell::validate
just shell::dump
just shell::verify
```

Shell-owned assets live here:

- `shell/*.env`
- `shell/*.err`
- `shell/*.out`

Shared implementation infrastructure lives at the repo root:

- `bin/`
- `src/`
- `Makefile`
- `Justfile`
- `bench.just`
- `make.just`
- `shell.just`
- `native.just`
- `compat.just`
- `corpus.just`
Today, the root `Justfile` exposes shared implementation probing/status via
`just impls`, and `shell.just` handles shell-specific reference generation and
verification.

The top-level `bin/envfile` is the general POSIX `sh` entry point. It parses
leading `format=`, `language=`, and `action=` key/value arguments, defaults to
`format=shell` and `action=validate`, and uses `awk` first with `perl`,
`bash`, `python`, and `sh` as fallback validators when no language is
specified.

It does not fundamentally depend on `mise` or any other package manager.
Some implementation backends may use `mise` for tool availability, but the
dispatcher itself stays self-contained.

The Makefile exposes `make now` and `make fast` as mode selectors for the
same build graph. `fast` is the default. Mode changes update the cached build
stamps under `.make/` and rebuild the final `bin/` outputs when the selected
flags differ. `now` biases toward faster compilation; `fast` biases toward
optimized binaries.

Right now, `native` routes through the native-capable backends, with `awk`
first, then `c`, `go`, `zig`, `bash`, `sh`, and `perl` as fallback options;
`compat` still routes to the shell baseline.

Example:

```sh
bin/envfile format=shell action=dump shell/accepted.env
```

Implementation entry paths are derived by a small built-in table:

- `bash` -> `bin/envfile.bash`
- `perl` -> `bin/envfile.pl`
- `python` -> `bin/envfile.py`
- `nushell` -> `bin/envfile.nu`
- `ruby` -> `bin/envfile.rb`
- `rust` -> `bin/envfile.rs`
- `node.js` -> `bin/envfile.node.js`

For interpreted implementations, the binary entry is the source file. For
native implementations, source lives under `src/<language>/`.

Shell diagnostics in the committed fixture/reference outputs are emitted as
`LINE_ERROR_*` codes. User-facing startup errors may still use plain text.

## Format

An envfile is a text file. Each line is either blank, a comment, or an
assignment.

### Blank lines

A line is blank if it is empty or contains only horizontal whitespace (spaces
and tabs). Blank lines are ignored.

### Comments

A line whose first character is `#` is a comment. Comments are ignored.

```text
# this is a comment
```

No inline comments. A `#` appearing after a key or value is not special.

### Assignments

```text
KEY=VALUE
```

The line is split at the first `=` character. Everything before is the key;
everything after is the value.

### Key

A key must match `[A-Za-z_][A-Za-z0-9_]*`.

Keys must not have leading or trailing whitespace.

Keys may be uppercase, lowercase, or mixed case. The shell parser preserves
them as written.

### Value

The value is everything after the first `=`. An empty value is valid:

```text
KEY=
```

Values must not have leading whitespace after the `=`.

There are three value forms.

#### 1. Unquoted

```text
KEY=value
```

A bare string. It must not contain whitespace, quotes (`'` or `"`), or
backslashes (`\`).

Examples:

```text
DATABASE_PATH=/data/app.db
COLOR=#ff0
EMPTY=
VALUE_WITH_EQUALS=base64://abc=def==
```

#### 2. Single-quoted

```text
KEY='value'
```

Delimited by `'`. The content between the quotes is taken literally, with no
escaping or interpretation. The content must not contain `'`.

Examples:

```text
QUOTED_SINGLE='hello world'
QUOTED_SINGLE_WITH_DOUBLE='she said "hi"'
QUOTED_BACKSLASH='path\to\file'
```

An opening `'` without a matching closing `'` is an error.

#### 3. Double-quoted

```text
KEY="value"
```

Delimited by `"`. The content between the quotes is taken literally, with no
variable expansion, no command substitution, and no escape sequences. The
content may include `'` and `\`.

Examples:

```text
QUOTED_DOUBLE="hello world"
QUOTED_DOUBLE_WITH_SINGLE="it's fine"
QUOTED_WITH_EQUALS="a=b=c"
```

An opening `"` without a matching closing `"` is an error.

This differs from POSIX shell semantics, where `$`, backtick, and `\` are
special inside double quotes. In `shell`, double-quoted values are purely
literal. There is no expansion.

### Constraint summary

| Condition | Result |
|---|---|
| No `=` in line | error |
| Leading whitespace before key | error |
| Trailing whitespace before `=` | error |
| Leading whitespace after `=` | error |
| Key not matching `[A-Za-z_][A-Za-z0-9_]*` | error |
| Key case | accepted |
| Unquoted value containing whitespace, quote, or backslash | error |
| Unterminated `'` | error |
| Unterminated `"` | error |
| Content after closing quote | error |
| Empty value (`KEY=`) | valid |
| Blank line | ignored |
| Line starting with `#` | ignored |
| Inline `#` after value | not special |

## Pseudocode

```text
function validate(file):
    for each line in file (numbered from 1):
        if line is empty or only whitespace:
            skip

        if line starts with '#':
            skip

        if '=' not in line:
            LINE_ERROR_NO_EQUALS
            skip

        split line at first '=' into key, value

        if key has leading whitespace:
            LINE_ERROR_KEY_LEADING_WHITESPACE
            skip

        if key has trailing whitespace:
            LINE_ERROR_KEY_TRAILING_WHITESPACE
            skip

        if value has leading whitespace:
            LINE_ERROR_VALUE_LEADING_WHITESPACE
            skip

        if key does not match /[A-Za-z_][A-Za-z0-9_]*/:
            LINE_ERROR_KEY_INVALID
            skip

        if value is empty:
            skip

        first = value[0]

        if first == '"':
            rest = value[1:]
            if '"' not in rest:
                LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED
                skip
            pos = index of first '"' in rest
            if rest[pos+1:] is not empty:
                LINE_ERROR_TRAILING_CONTENT
                skip

        else if first == "'":
            rest = value[1:]
            if "'" not in rest:
                LINE_ERROR_SINGLE_QUOTE_UNTERMINATED
                skip
            pos = index of first "'" in rest
            if rest[pos+1:] is not empty:
                LINE_ERROR_TRAILING_CONTENT
                skip

        else:
            if value contains whitespace, "'", '"', or '\':
                LINE_ERROR_VALUE_INVALID_CHAR
                skip
```

## Examples

### Valid (`shell/accepted.env`)

```text
# bare values
BIND_PORT=4321
DATABASE_PATH=/data/seatzero.db
SECRET_KEY_BASE=x703r57fJoLj2oS1yEXkiVmkxWrtZu9u
EMPTY_VALUE=
VALUE_WITH_EQUALS=base64://abc=def==
COLOR=#ff0
_UNDERSCORE_KEY=ok
KEY123=numbers_ok
QUOTED_DOUBLE="hello world"
QUOTED_SINGLE='hello world'
QUOTED_WITH_EQUALS="a=b=c"
QUOTED_EMPTY_DOUBLE=""
QUOTED_EMPTY_SINGLE=''
QUOTED_DOUBLE_WITH_SINGLE="it's fine"
QUOTED_SINGLE_WITH_DOUBLE='she said "hi"'
QUOTED_BACKSLASH='path\to\file'
```

Output:

```text
17 checked, 0 errors
```

### Invalid (`shell/rejected.env`)

```text
BIND_PORT=4000
123_BAD=oops                           # key starts with digit
noequals                               # missing =
export FOO=bar                         # space in key
KEY = val                              # whitespace around =
has space=value with spaces            # space in key
-hasdash=value                         # key starts with dash
=empty_key                             # empty key
        good_key_but_tab=value         # leading tab
UNTERMINATED_DOUBLE="no end quote      # missing closing "
UNTERMINATED_SINGLE='no end quote      # missing closing '
NESTED_SINGLE='can't nest'             # ' inside single quotes
MIXED_QUOTES="mixed'quotes"ok          # trailing content after "
```

Output:

```text
shell/rejected.env:2: LINE_ERROR_KEY_INVALID
shell/rejected.env:3: LINE_ERROR_NO_EQUALS
shell/rejected.env:4: LINE_ERROR_KEY_INVALID
shell/rejected.env:5: LINE_ERROR_KEY_TRAILING_WHITESPACE
shell/rejected.env:6: LINE_ERROR_KEY_INVALID
shell/rejected.env:7: LINE_ERROR_KEY_INVALID
shell/rejected.env:8: LINE_ERROR_KEY_INVALID
shell/rejected.env:9: LINE_ERROR_KEY_LEADING_WHITESPACE
shell/rejected.env:10: LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED
shell/rejected.env:11: LINE_ERROR_SINGLE_QUOTE_UNTERMINATED
shell/rejected.env:12: LINE_ERROR_TRAILING_CONTENT
shell/rejected.env:13: LINE_ERROR_TRAILING_CONTENT
13 checked, 12 errors
```

## Output format

All output goes to stderr. The validator exits 0 on success and 1 on any
error.

Each diagnostic is one line:

```text
CODE: filename:lineno
```

The committed fixture/reference outputs use `LINE_ERROR_*` codes for line
diagnostics, plus `FILE_ERROR_*` for file-fatal prepasses and `WARNING_BOM`
for the current warning case.

The final summary line is always printed:

```text
N checked, N errors
```

## Implementations

Canonical implementation naming follows the repo's derived naming convention:

- interpreted entry: `bin/envfile.<suffix>`
- native binary: `bin/envfile.<suffix>`
- native source: `src/<language>/`

Here, `<suffix>` means the language suffix used for the executable name.
For interpreted implementations, source and binary are the same file.

`bin/envfile` is the primary shell entry point.

The minimum support target is a machine with Git for Windows or any Unix. On
such a system the `base` implementations can be made to work by passing the
script directly to the runtime, for example:

```sh
awk -f bin/envfile.awk shell/accepted.env
perl bin/envfile.pl shell/accepted.env
```

`just` and `mise` are convenience, not part of the minimum execution model.

Implementations are classified along two dimensions.

### Runtime availability

| Class | Meaning | Examples |
|---|---|---|
| `base` | Present on any Unix and in Git for Windows | awk, sh, bash, perl |
| `installed` | Common on developer machines, not guaranteed | python, ruby |
| `mise` | Managed via `mise` | nu, node, bun, deno, go, zig, rust |

### Execution model

| Class | Meaning |
|---|---|
| `interpreted` | Runs via a runtime on PATH |
| `native` | Compiled to a binary |

Native implementations are never `base`. C is `installed` + `native`. Go,
Zig, Rust, and asm are `mise` + `native`.

### Interpreted implementations

| Binary | Language | Runtime | Source |
|---|---|---|---|
| `bin/envfile.awk` | AWK | base | `bin/envfile.awk` |
| `bin/envfile.sh` | sh | base | `bin/envfile.sh` |
| `bin/envfile.bash` | Bash | base | `bin/envfile.bash` |
| `bin/envfile.pl` | Perl | base | `bin/envfile.pl` |
| `bin/envfile.py` | Python | installed | `bin/envfile.py` |
| `bin/envfile.rb` | Ruby | installed | `bin/envfile.rb` |
| `bin/envfile.nu` | Nushell | mise | `bin/envfile.nu` |
| `bin/envfile.node.js` | Node.js | mise | `src/js/` |
| `bin/envfile.bun.js` | Bun | mise | `src/js/` |
| `bin/envfile.deno.js` | Deno | mise | `src/js/` |

### Native implementations

Require a build step (`make all` or individual `make <target>`; `just make`
is a thin wrapper around `make all`). The resulting binary
has no runtime dependency at execution time.

| Binary | Language | Toolchain | Source |
|---|---|---|---|
| `bin/envfile.c` | C | `cc` | `src/c/` |
| `bin/envfile.asm` | x86-64 asm | `nasm`, `ld` | `src/c/` |
| `bin/envfile.go` | Go | `mise` | `src/go/` |
| `bin/envfile.rs` | Rust | `mise` | `src/rust/` |
| `bin/envfile.zig` | Zig | `mise` | `src/zig/` |

## Setup

```sh
just impls
just make
just shell::validate
just shell::dump
just shell::verify
just shell::verify-normalize
just shell::check-bash
```

Reference outputs in `shell/*.err` and `shell/*.out` define correct output
for all implementations. The AWK implementation produced them and is the
canonical reference.

To regenerate reference outputs:

```sh
just shell::regen
just shell::regen-normalize
```

## Benchmark

Benchmarks are dominated by process startup cost. All shell spec files are
passed to each implementation per iteration.

```sh
bin/bench
bin/bench format=shell
bin/bench format=native
bin/pybench
```

For deeper notes on scheduler noise and mitigation, see
[docs/BENCHMARK_JITTER.md](../docs/BENCHMARK_JITTER.md).

## Future spec work

The current shell spec is already strong enough for implementors, but
the next leverage points are:

- a formal grammar
- normative language (`MUST`, `SHOULD`, etc.)
- machine-readable conformance metadata for `shell/`
- defined, versioned error codes

These are best treated as evolutions of the existing shell spec rather than as
a separate parallel specification effort.

## Related docs

- [../docs/STRATEGY.md](../docs/STRATEGY.md) — adoption and standardization strategy
- [../docs/DATA_GATHERING.md](../docs/DATA_GATHERING.md) — corpus gathering notes

## License

MIT
