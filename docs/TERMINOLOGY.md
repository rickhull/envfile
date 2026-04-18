# Terminology

Preferred terminology for this repository.

The goal is not to ban all synonyms. The goal is to have one primary term for
each concept, so code, docs, and discussion converge instead of drifting.

## Enums

Key-value pairs where the value is one of a fixed set:

| key        | values                              | notes                          |
|------------|-------------------------------------|--------------------------------|
| `format`   | `strict\|native\|compat`            |                                |
| `action`   | `validate\|normalize`               |                                |
| `execution`| `built\|scripted`                   |                                |
| `files`    | `fixtures\|corpus`                  | bench input source             |
| `mode`     | `now\|fast`                         | build optimization level       |
| `fixture`  | `accepted\|rejected\|warning\|...`  | first three are standard; rest are format-specific |
| `mise`     | `available\|unavailable`            |                                |
| `language` | `asm\|awk\|...`                     | open-ended                     |

`execution: built` means there is a build step that produces a distinct
executable artifact (C, Rust, Zig, Go, asm). `execution: scripted` means
the source file is the artifact — no build step, activated by `chmod +x`
(awk, bash, python, ruby, node, etc.).

## format

Primary term: `format`

Use for the thing itself:

- `strict`
- `native`
- `compat`

Examples:

- "`strict` is a format."
- "This implementation validates the `native` format."
- "The corpus may or may not conform to a given format."

Secondary / acceptable:

- `dialect`
- `variant`

Use these sparingly. Prefer `format` unless there is a clear reason not to.

Avoid as the primary term:

- `spec`

Reason:

- a format has a spec
- the spec describes the format
- the spec is not the thing being parsed

## spec

Primary term: `spec`

Use for the description or definition of a format.

Examples:

- "The strict spec lives in `strict/README.md`."
- "The native spec is still evolving."
- "The spec defines the diagnostics for the format."

Secondary / acceptable:

- `definition`
- `specification`

Do not use `spec` as the primary noun for `strict`, `native`, or `compat`
themselves when `format` is what you mean.

## implementation

Primary term: `implementation`

Use for a concrete validator/parser entry in this repo.

Examples:

- `bin/envfile.py` is a Python implementation
- `bin/envfile.c` is a C implementation
- benchmarks compare implementations
- verification iterates over implementations

Secondary / acceptable:

- `backend`

Use sparingly. Prefer `implementation`.

Avoid as the primary term:

- `language`
- `runtime`

Reason:

- multiple implementations may exist in one language
- runtime/toolchain describes how an implementation executes, not what it is

## action

Primary term: `action`

Use for the operation an implementation performs on input:

- `validate` — check input against the format, report diagnostics
- `normalize` — emit a canonical representation of valid input

Passed via the `ENVFILE_ACTION` environment variable or `action=` dispatcher
argument.

## validate

Primary term: `validate`

Use for the action of checking an input against a format.

Examples:

- "Validate the file."
- "This implementation validates the strict format."
- "The validator reports all errors before exiting."

Secondary / acceptable:

- `check`
- `verify`

Avoid as the primary term:

- `lint`

Reason:

- `lint` is historical and serviceable, but it now creates more confusion than clarity in this repo
- `validate` describes the action without implying a specific legacy tool shape

## execution

Primary term: `execution`

Use for whether an implementation has a build step:

- `built` — Makefile produces a distinct executable artifact from `src/`
- `scripted` — source file is the executable; activated with `chmod +x`

Examples:

- "C, Rust, Zig, Go, and asm are built implementations."
- "AWK, Python, and Ruby are scripted implementations."

The distinction does not imply anything about runtime architecture (JIT,
bytecode, native code) — only about whether the project builds it.

## language

Primary term: `language`

Use for the implementation language:

- `python`
- `ruby`
- `c`
- `rust`
- `zig`

Examples:

- "Group implementations by language."
- "The Ruby implementation is slower than the C implementation."

## tool

Primary term: `tool`

Use for the runtime or toolchain name associated with an implementation:

- `python3`
- `ruby`
- `cc`
- `zig`

Examples:

- "Check whether the required tool is available."
- "`tool = \"cc\"`"

Secondary / acceptable:

- `runtime`
- `toolchain`

Use those in prose when you need extra precision.

## corpus

Primary term: `corpus`

Use for the shared collection of real-world files used for:

- observing validator behavior
- measuring real-world acceptance/rejection
- benchmarking on varied material

The corpus is format-adjacent, not format-owned.

Examples:

- "`corpus/` is shared across formats."
- "Strict is currently used for corpus acceptance."
- "No format is expected to accept any particular fraction of the corpus."

## registry enums

Primary term: `registry enum` or `config enum`

Use for values that belong to machine-readable configuration rather than the
core conceptual vocabulary of the project.

Examples:

- `mise = available | unavailable`

These values matter and should be documented, but they are configuration
fields, not primary nouns for the repo's main mental model.

## Rules of thumb

- Prefer `format` over `spec` when talking about `strict`, `native`, or `compat`.
- Prefer `spec` for documents and rule definitions.
- Prefer `implementation` for concrete repo entries in `bin/`.
- Prefer `validate` over `lint` for the action of checking files.
- Prefer `language` for Python/Ruby/C/etc.
- Prefer `execution` for `built` vs `scripted`.
- Prefer `tool` in compact schema; use `runtime` or `toolchain` in prose if needed.
