# Terminology

Preferred terminology for this repository.

The goal is not to ban all synonyms. The goal is to have one primary term for
each concept, so code, docs, and discussion converge instead of drifting.

## Enums

Key-value pairs where the value is one of a fixed set:

| key        | values                              | notes                          |
|------------|-------------------------------------|--------------------------------|
| `format`   | `shell` `native` `compat`                      |                                |
| `action`   | `normalize` `validate` `dump` `delta` `apply`  |                                |
| `envfile_bom` | `literal` `strip` `reject`                   | normalize BOM policy           |
| `execution`| `built` `scripted`                             |                                |
| `files`    | `fixtures` `corpus`                            | bench input source             |
| `mode`     | `now` `fast`                                   | build optimization level       |
| `severity` | `warning` `error` `fatal`                      | message severity / policy enum |
| `fixture`  | `accepted` `rejected` `warning` `...`          | first three are standard; rest are format-specific |
| `mise`     | `available` `unavailable`                      |                                |
| `language` | `asm` `awk` `...`                              | open-ended                     |

`execution: built` means there is a build step that produces a distinct
executable artifact (C, Rust, Zig, Go, asm). `execution: scripted` means
the source file is the artifact — no build step, activated by `chmod +x`
(awk, bash, python, ruby, node, etc.).

## format

Primary term: `format`

Use for the thing itself:

- `shell`
- `native`
- `compat`

Examples:

- "`shell` is a format."
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

- "The shell spec lives in `shell/README.md`."
- "The native spec is still evolving."
- "The spec defines the diagnostics for the format."

Secondary / acceptable:

- `definition`
- `specification`

Do not use `spec` as the primary noun for `shell`, `native`, or `compat`
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

- `normalize` — parse syntax (join continuations, strip CRLF, NUL-reject), emit faithful `KEY=VALUE` pairs; foundational step for all actions above it
- `validate` — check normalized input against the format, report diagnostics
- `dump` — emit parsed values (for shell: quotes stripped); no env evaluation
- `delta` — compute the bindings a file would introduce or change, given an env
- `apply` — call `delta`, merge result into env, return new env

Passed via the `ENVFILE_ACTION` environment variable or `action=` dispatcher
argument.

## validate

Primary term: `validate`

Use for the action of checking an input against a format.

Examples:

- "Validate the file."
- "This implementation validates the shell format."
- "The validator reports all errors before exiting."

Secondary / acceptable:

- `check`

Avoid as the primary term:

- `lint` — historical and serviceable, but creates more confusion than clarity in this repo
- `verify` — reserved for the testing mechanism (diff against golden files); do not use as a synonym for the `validate` action

Reason:

- `validate` describes the action without implying a specific legacy tool shape
- keeping `verify` distinct from `validate` prevents ambiguity in recipe names and docs

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
- "Shell is currently used for corpus acceptance."
- "No format is expected to accept any particular fraction of the corpus."

## registry enums

Primary term: `registry enum` or `config enum`

Use for values that belong to machine-readable configuration rather than the
core conceptual vocabulary of the project.

Examples:

- `mise = available | unavailable`

These values matter and should be documented, but they are configuration
fields, not primary nouns for the repo's main mental model.

## processing (draft)

This section is early and tentative. The concepts are real but the terminology
is not yet settled.

The basic operation is: given an environment and a file, produce a new
environment. Every valid assignment in the file is applied to the environment,
potentially resolving variable references in values against the prior
environment.

Verbs that work in prose:

- "Apply the file to the environment."
- "Apply the file against the environment."
- "Resolve the variable references in the value."

The function shape is:

```
apply(env, file) → new_env
```

The verb is `apply`. "Resolution" refers only to the sub-step of expanding
`$VAR` references within a value.

Key distinction: **validation** checks whether a file is structurally correct.
**Processing** consumes a valid file and updates an environment. Validation does
not need an environment. Processing does — even if it's empty, in which case
variable references remain as literal bytes.

## verify

Primary term: `verify`

Use specifically for the mechanism of running an implementation against a
fixture and diffing the output against the golden file. It is the comparison
step inside a golden test.

Examples:

- "`just shell::verify` diffs all shell fixtures against their golden files."
- "Verify passes when output matches the golden file exactly."

`verify` is not a synonym for `validate`. `validate` is a pipeline action
performed on user files. `verify` is a testing operation performed on
implementations.

## generate

Primary term: `generate`

Use for the action of running the reference implementation against fixtures
and writing the results as golden files. Golden files must be reviewed
(via `git diff`) and committed intentionally — generation is not automatic
approval.

Examples:

- "`just shell::generate` regenerates the shell golden files."
- "Generate golden files after an intentional behavior change, then review the diff."

Recipe name: `regen` (short, unambiguous, clearly imperative).

Avoid:

- `generate` — prefer `regen` in recipe names; `generate` is acceptable in prose
- `reference` as a verb or gerund ("referencing", "generating references") —
  prefer `regen` for the action and `golden file` for the artifact

## test

Primary term: `test`

Use as the umbrella verb and noun for any activity that checks correctness.
The root `just test` recipe runs the shell and native golden-test suites.

Examples:

- "Run the tests."
- "Does this pass the test suite?"
- "`just test` runs the golden tests for shell and native."

`test` intentionally subsumes narrower terms (`verify`, `check`, `golden`).
Use those narrower terms only when precision about the *kind* of test matters.

## golden test

Primary term: `golden test`

Use for the pattern of running an implementation against a **fixture** and
diffing the output against a committed **golden file**. All fixture-based
verification in this repo is golden testing.

Examples:

- "`just shell::verify` runs the golden tests for the shell format."
- "Regenerate the golden files after an intentional behavior change."
- "Golden tests are cross-implementation by construction."

Secondary / acceptable:

- `snapshot test` — same mechanism; avoid here because it implies
  auto-update workflows (Jest-style) that we do not use
- `approval test` — same mechanism, different emphasis; acceptable in prose

Avoid:

- `regression test` — imprecise; every test is a regression guard

## fixture

Primary term: `fixture`

Use for an input file used in golden testing. Fixtures live under
`shell/`, `native/`, etc., organized by concern (`accepted/`, `rejected/`,
`mixed/`, `normalize/`, `delta/`).

Examples:

- "`shell/accepted/accepted.env` is a fixture."
- "Add a fixture to cover the new edge case."
- "Fixtures are shared across all implementations."

A fixture on its own is just an input. It becomes a test when paired with a
golden file.

## golden file

Primary term: `golden file`

Use for the committed expected-output file paired with a fixture. Also called
a **sidecar** (see below) when the file lives next to the fixture it belongs to.

Examples:

- "The golden file records the expected stderr for this fixture."
- "Diff the output against the golden file."

A missing golden file is an assertion of empty content, not a missing test.

Secondary / acceptable:

- `reference` — acceptable in prose ("the reference output", "check against the reference")

Avoid:

- `reference` as the primary term in recipe names or code — prefer `golden`
  so the testing pattern is named consistently throughout

## sidecar

Primary term: `sidecar`

Use for the physical arrangement: a golden file that lives next to its fixture
and shares its base name.

```
shell/accepted/accepted.env       ← fixture
shell/accepted/accepted.err       ← sidecar (golden file for stderr)
shell/normalize/bom.env           ← fixture
shell/normalize/bom.BOM=literal.err  ← sidecar (golden file for a specific mode)
```

`sidecar` describes *where the file lives*. `golden file` describes *what it is*.
Use `sidecar` when talking about file layout; use `golden file` when talking
about test semantics.

## Rules of thumb

- Prefer `format` over `spec` when talking about `shell`, `native`, or `compat`.
- Prefer `spec` for documents and rule definitions.
- Prefer `implementation` for concrete repo entries in `bin/`.
- Prefer `validate` over `lint` for the action of checking files.
- Prefer `language` for Python/Ruby/C/etc.
- Prefer `execution` for `built` vs `scripted`.
- Prefer `tool` in compact schema; use `runtime` or `toolchain` in prose if needed.
- Prefer `process` or `apply` for the operation of turning a file into an updated environment.
- Prefer `test` as the umbrella; use `golden test` when the mechanism matters.
- Prefer `golden file` for semantics; use `sidecar` for file layout; `reference` is acceptable in prose.
- Prefer `fixture` for input files; a fixture without a golden file is not yet a test.
- Prefer `verify` for the diff-against-golden mechanism; never use it as a synonym for `validate`.
- Prefer `regen` in recipe names; `regenerate` or `generate` are acceptable in prose.
