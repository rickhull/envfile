# Warning Stage

This note proposes an optional `warn` stage in the `envfile` pipeline.

## Goal

The warning stage should let implementations report policy concerns without
discarding usable data. It runs after validation and before any later
processing that depends on the validated record stream.

The core idea is:

- keep values flowing when they are still structurally usable
- let upstream policy decide whether a warning is acceptable
- avoid hard-coding policy into the parser backend

## Control Surface

`warn` is controlled entirely by external rules or configuration.

At baseline, that means `ENVFILE_*` environment variables and dispatcher-level
policy inputs. The implementation should not infer policy from the file alone.

The caller defines:

- which patterns or content are interesting
- whether a warning is informational or actionable
- whether warnings should be counted, surfaced, or ignored

## Behavior

The warning stage is primarily a content filter, but it may grow to cover other
policy checks as long as they remain non-syntactic.

Examples of warning-worthy content:

- BOM at byte 0, if warning policy opts in separately from normalize mode
- unusual bytes that are still technically representable
- values that are legal but suspicious
- records that are valid but violate a caller's preferred policy

Existing warning class:

- none (current contract has no warning diagnostics)

The stage should not mutate the underlying record unless a policy layer
explicitly asks it to do so.

## Escalation

Warnings may be escalated by policy.

Possible modes:

- warn only
- warn and continue
- warn and fail
- fatal

The important distinction is that escalation is external. The stage itself
only reports what it found.

## Design Preference

Prefer the following order of responsibility:

1. parser/backend determines what is syntactically valid
2. warning policy determines what is noteworthy
3. dispatcher or caller decides whether warnings are fatal

This keeps the pipeline flexible and makes it easier to reuse the same
implementation under different policy regimes.

## Open Questions

- Which additional warning classes belong in the core repo contract versus
  later policy extensions?
- Should shell-only name policy become a warning class before any other
  content checks?
- Should the default be warning-only, or warning plus nonzero exit status?

## Proposed Warning Classes

These are candidates, not commitments:

- BOM-at-byte-0 policy warnings, if we choose to add a warning class later
- shell-format lowercase keys, if we want shell to accept-and-warn instead of
  accept-and-ignore
- shell-format suspicious but representable value content

Native should stay out of this list unless a warning is truly about policy and
not syntax. The current native contract is intentionally literal.
