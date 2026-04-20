# native

`envfile/native` is the current POSIX-native, byte-oriented format.

Unlike `shell`, `native` does not need to fit itself into the assumptions of
the current shell ecosystem. It can share as much or as little implementation
infrastructure as is pragmatic.

Current status:

- accepted and rejected fixtures under `native/accepted/` and
  `native/rejected/`
- normalize fixtures under `native/normalize/`
- delta fixtures under `native/delta/`
- apply fixtures under `native/apply/`
- binary fixtures are covered by the default `native::verify` loop and gated
  by `bin/nullscan`
- file-level NUL rejection is handled by `bin/nullscan`; `make nullscan` can
  replace it locally with the compiled helper before the parser runs
- reference outputs are committed as `.err` and `.out` sidecars next to each
  fixture
- validate-mode references are code-first: `LINE_ERROR_*` are emitted as
  `CODE: file:line`
- implementation entrypoint: `native.just`
- implementation status: active and covered by golden tests

The fixture set is intentionally small. What matters right now is the shape
of the parser contract:

1. File-level
   - Can we open and read the file?
   - Can we reject NUL cleanly? Yes, via the file gate.
   - Failures here are hard failures.

2. Record-level
   - Can we split the file on newlines?
   - A missing trailing newline is not special.
   - Empty input is allowed and means “no bindings”.

3. Line-level
   - Blank line: ignored
   - Comment line: ignored if the first byte is `#`
   - Assignment line: `KEY=VALUE`
   - Anything containing NUL is rejected by the file gate first

4. Assignment-level
   - `KEY` must be nonempty and follow the key rules
   - `VALUE` may be empty
   - `=VALUE` is rejected with `LINE_ERROR_EMPTY_KEY`
   - malformed assignments are rejected, not silently retained

That gives us a useful vocabulary even before the fixture set is finalized:

- **accepted**: registered and retained
- **rejected**: malformed enough to report as an error
- **ignored**: blank or comment lines

These categories are for organizing the current fixture set and future edge
cases, not for freezing the corpus prematurely.

The current tool model is:

- `action=validate` is the default: diagnostics go to `stderr`, exit status
  reflects success or failure, and accepted input is not echoed.
- `action=dump` is the filter: accepted lines are emitted as `KEY=VALUE` on
  `stdout`, rejected lines are omitted from `stdout`, and diagnostics still
  go to `stderr`.
- if no files are given, the tool reads `stdin`.

Native workflow entrypoints:

```sh
just impls
just native::validate
just native::dump
just native::delta
just native::verify
just native::verify-normalize
just native::regen
just native::regen-normalize
just native::regen-delta
```

Implementation infrastructure is shared at the repo root:

- `bin/` — one entry per implementation
- `src/` — implementation sources
- `Makefile` — primary native build graph
- `bench.just` — shared benchmark helpers

Format-specific native material lives directly in `native/`:

- `native/README.md` — native format spec
- `native/accepted/` and `native/rejected/` — fixture sets
- `native/*.err` and `native/*.out` under those subdirs — expected outputs

`corpus/` remains top-level, because it is intended to be shared real-world
material for validation and benchmarking across formats. `shell` may be used
for corpus acceptance, but the corpus itself is not owned by `shell`.

## The format

`native` is a file format for representing a POSIX-style environment as
directly as possible.

The underlying POSIX model is an environment block in memory: a sequence of
null-terminated C strings, each string conventionally shaped like `KEY=VALUE`.
`native` keeps that model, but maps it onto a line-oriented file:

- memory record separator: `\0`
- `native` file record separator: `\n`
- C strings disallow `\0`
- `native` records disallow `\n`

Each line is one environment entry. The format is intentionally literal. There
is no shell syntax, no escapes, no interpolation, and no substitution. Values
are values.

## Core model

A `native` file is zero or more newline-terminated records.

Each record is:

```text
KEY=VALUE\n
```

The first `=` byte separates key from value.

Everything before the first `=` is the key. Everything after it is the value.
The value may be empty. The key may be syntactically empty at the raw
POSIX-model level, but `native` rejects empty keys as invalid because they are
not useful in practice.

## Byte Rules

Only three bytes are special to the format:

- `\0` is forbidden anywhere in the file
- `\n` ends a record
- `=` splits key from value

### Key charset

`native` follows the POSIX environment-entry model rather than shell-utility
name syntax. The key is the name part of a `name=value` entry.

More precisely:

```text
name=value
```

More explicitly:

- key must be non-empty
- key must not contain `=`
- lowercase is allowed in `native`
- any other name bytes are preserved literally
- `=` is invalid in keys

This matches the POSIX environment model. The shell-utility uppercase subset
is relevant to shell-oriented formats, not to `native`.

### Value charset

The value is the literal text after the first `=`.

- Any bytes other than `\0` and `\n` are allowed.
- `=` may appear in the value.
- Newline and NUL are not allowed in the value.

## Semantics

`native` is literal:

- no interpolation
- no substitution
- no continuation lines
- no comments inside a record
- no trimming of surrounding whitespace

## Parsing rule

To parse a line:

1. Read the file line by line.
2. Ignore blank lines.
3. Ignore lines whose first byte is `#`.
4. For each remaining line, split at the first `=`.
5. Validate that the key is non-empty.
6. Accept the remainder as the literal value.

## Examples

Valid:

```text
FOO=bar
PORT=8080
EMPTY=
GREETING=hello world
FOO BAR=baz
JSON={"a":1}
PATH_LIKE=/usr/local/bin:/usr/bin
EQUALS=base64://abc=def==
HASH=#comment_looking
DOLLAR=$HOME/bin
```

Invalid:

```text
=bar
FOO
```

Why invalid:

- empty key
- missing `=`

The lowercase example `foo=bar` is valid in `native`.

## Design intent

`native` is meant to reflect the actual environment model, not shell syntax.

It should feel like “serialized `envp`”:

- one entry per line
- direct `KEY=VALUE` representation
- no interpretation layer
- bytes instead of interpreted text
- newline as the file-record terminator in place of NUL

It is not trying to be shell-compatible text. It is trying to be environment
data serialized into a line-oriented byte file.

That makes it simpler than shell-oriented formats and more direct than formats
that support comments, escaping, or substitution.

## Positioning relative to other formats

- `shell`: existing envfile format with stronger syntax and policy choices
- `compat`: possible future relaxed format for broader ecosystem input
- `native`: direct POSIX-style environment serialization, literal values, and
  only three special bytes: `=`, `\n`, and `\0`

A useful summary is:

- `shell` optimizes for discipline
- `compat` would optimize for acceptance
- `native` optimizes for fidelity to the underlying environment model

## Short definition

If you want an even tighter version for docs:

> `native` is a line-oriented byte format for literal POSIX-style environment
> entries. Each line is a single `KEY=VALUE` record terminated by `\n`. Keys
> are restricted to portable env-style identifiers, values are arbitrary bytes
> excluding newline and NUL, and no escaping, substitution, or comment syntax
> is recognized.
