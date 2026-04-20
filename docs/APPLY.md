# apply

The five actions form a pipeline, each building on the previous:

```
normalize(file)         → canonical KEY=VALUE lines
validate(file)          → ok | errors
dump(file)              → bindings (parsed)
delta(env, file)        → bindings (substituted)
apply(env, file)        → new_env
```

- `normalize` — join continuations, normalize line endings, reject NUL; emit faithful `KEY=VALUE`
- `validate` — is the file well-formed?
- `dump` — what bindings does the file declare, parsed? For shell: quotes stripped. No env, no substitution.
- `delta` — what bindings does the file produce, given this env? Same as dump but with variable substitution.
- `apply` — what is the new env after merging the delta in?

`dump` is `delta` with no substitution. `apply` is `delta` followed by a merge.

## delta

```
delta(env, file) → bindings
```

Walk the file top to bottom. For each valid assignment:

1. Extract the key and value.
2. Substitute `$VAR` and `${VAR}` references against the current working env.
3. Emit `KEY=value`.
4. Update the working env with the new binding so subsequent lines see it.

The working env starts as a copy of the input env. It accumulates bindings as
each line is processed. The input env is never mutated.

The delta is simply the set of bindings the file produces. It does not encode
what was in the env before — whether a binding is an introduction or an
overwrite is invisible to delta. That distinction only appears when `apply`
merges the delta into the env.

## apply

```
apply(env, file) → new_env
```

Compute `delta(env, file)`, then merge into env. For each binding in the delta:

- if the key was not in env — introduce it
- if the key was already in env — overwrite it

Keys in the input env not present in the file are untouched.

`apply` writes the full resulting env to stdout — the input env merged with
the delta. Output order is lexical by key so fixtures are deterministic.
Dispatcher/runtime shim vars such as `ENVFILE_*` are not part of the emitted
environment.

## Variable substitution

`$VAR` or `${VAR}` in a value is replaced with the bound value from the
working env at the time that line is processed.

```
# input env: HOME=/home/rwh
PATH=$HOME/bin:$PATH
# delta:     PATH=/home/rwh/bin:<whatever PATH was>
# new_env:   env ∪ {PATH=/home/rwh/bin:...}
```

### Missing references

If `$FOO` is not bound in the working env, the reference resolves to the empty
string, a diagnostic is emitted, and exit is nonzero. Processing continues.

```
# input env: {}
BAR=$FOO
# delta:     BAR=
# diagnostic: LINE_ERROR_UNBOUND_REF (FOO): file:line
```

This is an error. The caller passed an insufficient env. Pass a more complete
env — do not loosen the semantics.

### Literal values

Values with no variable references are taken as-is. No substitution occurs.

## Per-format notes

### shell

Quoting determines where substitution applies:

- double-quoted values (`"$HOME/bin"`) — substitution applies to the interior
- single-quoted values (`'$HOME/bin'`) — literal, no substitution
- unquoted values — `$` is rejected by the format, so substitution is moot

### native

Native values are byte-literal by design. `$VAR` is a legal sequence of bytes
in a native value. Substitution applies per the general rule, but native's
design intent means callers will typically pass an empty env. An empty env
means all `$VAR` references are unbound errors — so for native, `apply` is
most useful when called with an explicit env and the caller knows what they
want.

### compat

Compat is the primary target. Values may contain `$VAR`, `${VAR}`, backslash
escapes, and continuation lines. Substitution is the normal case.

## CLI surface

The input env is the process environment minus `ENVFILE_*` control vars. The
caller composes the environment before invoking.

```sh
HOME=/home/rwh envfile format=compat action=delta some.env   # bindings only
HOME=/home/rwh envfile format=compat action=apply some.env   # full new env
```

`action=apply` writes the full resulting env to stdout as `KEY=VALUE` lines.
`action=delta` writes only the bindings from the file, after substitution.

## Open questions

- **Diagnostic code name** — `LINE_ERROR_UNBOUND_REF` consistent with
  existing `LINE_ERROR_*` codes?
- **`${VAR:-default}` and friends** — out of scope for now, not ruled out.
