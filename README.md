# envfile — a strict subset of .env

Intended for developers working with cloud, containers, Kubernetes, 12-factor
applications, secrets management, and any system that ingests `.env` files.

`.env` is not a standard. Shells, Docker, `dotenv` libraries, Kubernetes
secret loaders, and CI systems all parse it differently. Files that appear
valid in one context fail silently in another.

**envfile** is a formal specification of a strict, minimal subset: one
assignment per line, no interpolation, no variable references, no command
substitution, no `export` prefix. The spec is accompanied by a linter
implemented independently in multiple languages — correctness is validated
by agreement across implementations, not by a single authoritative parser.

The project is Unix-oriented. [mise](https://mise.jdx.dev/) is the single
bootstrap dependency — it installs [just](https://just.systems/) and all
language toolchains declared in `.mise.toml`. The linter scripts themselves
run on any system with basic Unix tools or Git for Windows.

## Format

An envfile is a text file. Each line is either **blank**, a **comment**,
or an **assignment**.

### Blank lines

A line is blank if it is empty or contains only horizontal whitespace
(spaces and tabs). Blank lines are ignored.

### Comments

A line whose first character is `#` is a comment. Comments are ignored.

```
# this is a comment
```

No inline comments. A `#` appearing after a key or value is not special.

### Assignments

```
KEY=VALUE
```

The line is split at the first `=` character. Everything before is the
**key**; everything after is the **value**.

### Key

A key must match `[A-Za-z_][A-Za-z0-9_]*` — that is: a letter or
underscore, followed by zero or more letters, digits, or underscores.

Keys must not have leading or trailing whitespace.

**UPPERCASE keys are preferred** but not required. A lowercase or
mixed-case key is a warning, not an error.

### Value

The value is everything after the first `=`. An empty value is valid
(`KEY=`).

Values must not have leading whitespace after the `=`.

There are three value forms:

#### 1. Unquoted (bare)

```
KEY=value
```

A bare string. Must not contain whitespace, quotes (`'` `"`), or
backslashes (`\`).

```
DATABASE_PATH=/data/app.db
COLOR=#ff0
EMPTY=
VALUE_WITH_EQUALS=base64://abc=def==
```

#### 2. Single-quoted

```
KEY='value'
```

Delimited by `'`. The content between the quotes is taken literally,
with no escaping or interpretation. The content must not contain `'`.

```
QUOTED_SINGLE='hello world'
QUOTED_SINGLE_WITH_DOUBLE='she said "hi"'
QUOTED_BACKSLASH='path\to\file'
```

An opening `'` without a matching closing `'` is an error.

#### 3. Double-quoted

```
KEY="value"
```

Delimited by `"`. The content between the quotes is taken literally,
with no variable expansion, no command substitution, and no escape
sequences. The content may include `'` and `\`.

```
QUOTED_DOUBLE="hello world"
QUOTED_DOUBLE_WITH_SINGLE="it's fine"
QUOTED_WITH_EQUALS="a=b=c"
```

An opening `"` without a matching closing `"` is an error.

**Note:** This differs from POSIX shell semantics, where `$`, backtick,
and `\` are special inside double quotes. In envfile, double-quoted
values are purely literal. There is no expansion.

### Constraint summary

| Condition | Result |
|---|---|
| No `=` in line | error |
| Leading whitespace before key | error |
| Trailing whitespace before `=` | error |
| Leading whitespace after `=` | error |
| Key not matching `[A-Za-z_][A-Za-z0-9_]*` | error |
| Key not UPPERCASE | warning |
| Unquoted value containing whitespace, quote, or backslash | error |
| Unterminated `'` | error |
| Unterminated `"` | error |
| Content after closing quote | error |
| Empty value (`KEY=`) | valid |
| Blank line | ignored |
| Line starting with `#` | ignored (comment) |
| Inline `#` after value | not special |

## Pseudocode

```
function validate(file):
    for each line in file (numbered from 1):
        if line is empty or only whitespace:
            skip

        if line starts with '#':
            skip    # comment

        if '=' not in line:
            ERROR_NO_EQUALS
            skip

        split line at first '=' into key, value

        if key has leading whitespace:
            ERROR_KEY_LEADING_WHITESPACE
            skip

        if key has trailing whitespace:
            ERROR_KEY_TRAILING_WHITESPACE
            skip

        if value has leading whitespace:
            ERROR_VALUE_LEADING_WHITESPACE
            skip

        if key does not match /[A-Za-z_][A-Za-z0-9_]*/:
            ERROR_KEY_INVALID
            skip

        if key != uppercase(key):
            WARN_KEY_NOT_UPPERCASE

        if value is empty:
            skip    # valid

        first = value[0]

        if first == '"':
            rest = value[1:]
            if '"' not in rest:
                ERROR_DOUBLE_QUOTE_UNTERMINATED
                skip
            pos = index of first '"' in rest
            if rest[pos+1:] is not empty:
                ERROR_TRAILING_CONTENT
                skip

        else if first == "'":
            rest = value[1:]
            if "'" not in rest:
                ERROR_SINGLE_QUOTE_UNTERMINATED
                skip
            pos = index of first "'" in rest
            if rest[pos+1:] is not empty:
                ERROR_TRAILING_CONTENT
                skip

        else:
            if value contains whitespace, "'", '"', or '\':
                ERROR_VALUE_INVALID_CHAR
                skip
```

## Examples

### Valid (`spec/accepted.env`)

```
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

```
17 checked, 0 errors, 0 warnings
```

### Invalid (`spec/rejected.env`)

```
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

```
spec/rejected.env:2: invalid key '123_BAD'
spec/rejected.env:3: missing assignment (=)
spec/rejected.env:4: invalid key 'export FOO'
spec/rejected.env:5: whitespace before =
spec/rejected.env:6: invalid key 'has space'
spec/rejected.env:7: invalid key '-hasdash'
spec/rejected.env:8: invalid key ''
spec/rejected.env:9: leading whitespace before key
spec/rejected.env:10: unterminated double quote
spec/rejected.env:11: unterminated single quote
spec/rejected.env:12: trailing content after closing quote
spec/rejected.env:13: trailing content after closing quote
13 checked, 12 errors, 0 warnings
```

## Output format

All output goes to **stderr**. The linter exits 0 on success, 1 on any
error.

Each diagnostic is one line:

```
filename:lineno: message
```

The final summary line is always printed:

```
N checked, N errors, N warnings
```

## Implementations

Each implementation lives in `bin/lint.<ext>`. `bin/lint` is a symlink to
the best available reference implementation, created by `just activate`.

The minimum support target is a machine with [Git for Windows](https://gitforwindows.org/)
or any Unix. On such a system the `base` implementations can be made to work —
either by passing the script directly to the runtime (`awk -f bin/lint.awk ...`,
`perl bin/lint.pl ...`) or by setting the executable bit manually. No `just`
or `mise` required, but no hand-holding either.

Implementations are classified along two dimensions:

**Runtime availability** — what's needed to run it:

| Class | Meaning | Examples |
|---|---|---|
| `base` | Present on any Unix and in [Git for Windows](https://gitforwindows.org/) — the minimum support target | awk, sh, bash, perl |
| `installed` | Common on developer machines, not guaranteed | python, ruby |
| `mise` | Managed via [mise](https://mise.jdx.dev/) | nu, node, bun, deno, go, zig, rust |

**Execution model** — how it runs:

| Class | Meaning |
|---|---|
| `interpreted` | Runs via a runtime; the runtime must be on PATH |
| `native` | Compiled to a binary; build step required, no runtime dependency |

Native implementations are never `base`. C is `installed`+`native` (needs `cc`);
Go, Zig, Rust, and asm are `mise`+`native`.

### Interpreted implementations

| Binary | Language | Runtime | Source |
|---|---|---|---|
| `bin/lint.awk` | AWK | base | `bin/lint.awk` |
| `bin/lint.sh` | sh | base | `bin/lint.sh` |
| `bin/lint.bash` | Bash | base | `bin/lint.bash` |
| `bin/lint.pl` | Perl | base | `bin/lint.pl` |
| `bin/lint.py` | Python | installed | `bin/lint.py` |
| `bin/lint.rb` | Ruby | installed | `bin/lint.rb` |
| `bin/lint.nu` | Nushell | mise | `bin/lint.nu` |
| `bin/lint.nodejs` | Node.js | mise | `impl/js/` |
| `bin/lint.bun` | Bun | mise | `impl/js/` |
| `bin/lint.deno` | Deno | mise | `impl/js/` |

### Native implementations

Require a build step (`just build::all` or individually); the resulting
binary has no runtime dependency at execution time.

| Binary | Language | Toolchain | Source |
|---|---|---|---|
| `bin/lint.c` | C | installed (`cc`) | `impl/c/` |
| `bin/lint.asm` | x86-64 asm | installed (`nasm`, `ld`) | `impl/asm/` |
| `bin/lint.go` | Go | mise | `impl/go/` |
| `bin/lint.rs` | Rust | mise | `impl/rust/` |
| `bin/lint.zig` | Zig | mise | `impl/zig/` |

### Setup

```sh
just activate        # probe runtimes; set +x on available impls; create bin/lint symlink
just build::all      # compile all native impls (requires mise tools installed)
just verify          # verify all executable impls against reference output
```

### Reference outputs

The `spec/*.txt` files are committed to the repository — they define correct
output for all implementations. The AWK implementation produced them and is
the canonical reference.

`just generate-reference` regenerates them from `bin/lint`. Committers run
this when the spec changes. Anyone can run it; `git diff` will show any
divergence, which is mostly a curiosity on a clone where AWK is available.

### Benchmark

Benchmarks are dominated by process startup cost. All four spec files are
passed to each impl per iteration.

```
$ bin/bench
linter        iter/s        vs awk
--------      ------        ------
asm           2600.0  6.73x faster
c             1550.0  4.01x faster
rs            1250.0  3.24x faster
zig           1100.0  2.85x faster
go             680.0  1.76x faster
awk            386.0    (baseline)
pl             165.0  2.34x slower
...
```

```sh
bin/bench                              # all executable impls (C, Welford, mean+min)
bin/pybench                            # same, pure Python stdlib
```

## Why

.env files are parsed differently by every tool — shells, containers,
systemd, language runtimes. This project defines a strict, testable
subset that behaves the same way everywhere.

No interpolation. No ambiguity. Just keys and values.

## License

MIT
