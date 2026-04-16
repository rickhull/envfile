# Formal spec — brainstorming and planning

## Current state

The README.md is close to spec-quality: it defines the format precisely,
includes a pseudocode algorithm, constraint summary, and examples. The
main gaps are a formal grammar, normative language, machine-readable
conformance tests, and defined error codes.

## Grammar

A formal grammar eliminates ambiguity and gives implementors a single
authoritative reference. Two candidates:

**ABNF** (RFC 5234) — the right choice if the goal is eventual
standardisation or RFC-style credibility. Familiar to protocol engineers.
Used by HTTP, SMTP, URI specs.

**PEG** — more precise about parsing order; eliminates ambiguity by
construction. More familiar to compiler/parser authors. Tools like `peg`,
`pest` (Rust), or `lark` (Python) can consume it directly.

The envfile grammar is simple enough that both fit on half a page. A
PEG grammar would double as an executable reference parser. ABNF would
signal standardisation intent. Both are worth writing; PEG first.

## Normative language

RFC 2119 keywords (MUST, SHOULD, MAY, MUST NOT, SHOULD NOT) distinguish
hard requirements from soft preferences. The README currently mixes them:

- UPPERCASE keys being "preferred" is a SHOULD
- The key regex is a MUST
- No inline comments is a MUST NOT

A `SPEC.md` using normative language would be the authoritative document;
the README becomes a friendlier introduction that references it.

## Conformance test suite

The `spec/` directory is already embryonically a conformance suite.
Making it machine-readable (a JSON or TOML manifest) would allow external
implementations to self-certify without depending on this repo's tooling.

Each test case would specify:
- input (inline or file reference)
- expected outcome: pass / fail / warn
- expected error code(s)
- line number(s) where errors occur

The existing `accepted.env`, `rejected.env`, `warning.env` and their
`.txt` reference outputs cover the happy path. A manifest would make the
error code → line mapping explicit and language-agnostic.

This is the highest-leverage artifact for adoption: if implementors can
run `envspec test ./myparser` and get a pass/fail, the spec has gravity.

## Error codes

The pseudocode already uses symbolic constants (`ERROR_NO_EQUALS`,
`WARN_KEY_NOT_UPPERCASE`, etc.). Formalising these as a defined,
versioned enumeration means:

- Implementations can return structured errors, not just strings
- The conformance suite can assert specific codes, not just messages
- Go and Zig impls naturally express these as enums
- Error messages become an implementation detail; codes are the contract

See current codes below and the enumeration planning section.

## Parser spec (vs linter spec)

There is a meaningful distinction:

- **Linter**: validates input, reports human-readable diagnostics, exits
  0 or 1. What the current implementations do.
- **Parser**: validates input, returns a structured map of key→value
  pairs for runtime use (loading env vars into a process).

Both share the validation algorithm. The parser additionally defines:
- what data structure is returned on success
- how errors are surfaced to the caller (exception, result type, errno)
- whether partial results are returned on error

The spec should address both. The linter spec is nearly complete; the
parser spec is currently implicit.

## Versioning

Once the grammar and error codes stabilise, the spec needs a version.
Even `0.1` gives adopters something to reference and signals that breaking
changes will be communicated. Defer until grammar and error codes are
settled.

## Priority order

1. Formalise error codes / enumeration (unblocks conformance suite)
2. Write PEG grammar (short, precise, potentially executable)
3. Machine-readable conformance test manifest
4. Parser spec (data model + error surfacing)
5. Normative language / SPEC.md
6. Versioning
