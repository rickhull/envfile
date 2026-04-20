# Processing

This note is mostly superseded by [`docs/APPLY.md`](../APPLY.md). The core
processing model is now real in the reference path:

- `delta(env, file)` resolves bindings against a working environment
- `apply(env, file)` merges those bindings into the environment

The remaining items here are future extensions, not current contract.

Processing is the step after validation: given a prior environment and a valid
file, produce a new environment.

This is separate from validation. Validation answers "is this file well-formed?"
Processing answers "what environment does this file produce?"

## The core operation

```
resolve(env, file) → new_env
```

Walk the file top to bottom. For each valid assignment:

1. Extract key and value.
2. If the value contains variable references, resolve them against `env`.
3. Add or update `KEY=resolved_value` in the new environment.

The prior environment is passed in. It may be empty. The output is a new
environment (or the same one, mutated).

## Variable resolution

The simplest case: `$VAR` or `${VAR}` in a value is replaced with the value of
`VAR` from the prior environment. If `VAR` is not set, the reference remains as
literal text.

This matches systemd's `merge_env_file` behavior. It also matches what a shell
does inside double quotes (minus backtick expansion and command substitution).

### What compat accepts vs. what processing resolves

The compat parser treats `$`, backtick, and `${` as literal bytes during
validation. Processing is a separate step that may resolve them. This means:

- `FOO=$HOME/bin` validates fine in compat.
- `resolve({"HOME": "/home/rwh"}, file)` produces `FOO=/home/rwh/bin`.
- `resolve({}, file)` produces `FOO=$HOME/bin` (no substitution).

The same file, different outcomes depending on the environment passed in.

### Out of scope for now

- `${VAR:-default}` — extended substitutions
- `${VAR:+alternate}` — alternate substitutions
- Nested references like `${${VAR}}`
- Command substitution (`$(...)` or backtick)
- These are not ruled out forever. They are just not the first target.

## Relationship to existing systemd code paths

systemd has two code paths for reading env files:

1. **`load_env_file`** — pure parse-and-collect. No variable expansion. Used by
   `EnvironmentFile=` in service units. This is `resolve(empty_env, file)`.

2. **`merge_env_file`** — parse, expand `$VAR` against the accumulator, then
   collect. Used by `environment.d`. This is `resolve(accumulator, file)` where
   the accumulator grows as each file is processed.

envfile's processing model covers both: pass an empty environment for the
no-expansion case, or pass the running accumulator for the expansion case.

## Per-format processing notes

### shell

Shell format values are already unambiguous after parsing. Variable references
in double-quoted values (`"$HOME"`) were preserved literally by the validator.
Processing would resolve them if provided an environment.

Shell format in unquoted and single-quoted values has no variable references by
construction (unquoted values can't contain `$`, single-quoted values are
literal).

### native

Native format has no quoting and no special characters in values. `$VAR` in a
native value is always literal bytes. Processing could resolve it, but native's
design intent is zero interpretation — so processing for native would typically
be the identity operation.

### compat

Compat is the primary target for processing. Its values may contain `$VAR`,
`'`, `"`, backslash escapes, and line continuations. Processing needs to:

1. Handle escape sequences during value extraction (the parser may already do
   this during normalization).
2. Resolve variable references against the provided environment.
3. Return the final key-value pairs.

## Status

Core processing is implemented in the reference path and covered by golden
tests. This note only tracks future expansion ideas now.
