# Pipeline

Each implementation models five actions as a pipeline of discrete stages.
The requested `action=` determines how far execution proceeds. Every action
implicitly runs all prior stages.

```
normalize → validate → dump → delta → apply
```

| Action      | Produces                    |
|-------------|-----------------------------|
| `normalize` | canonical `KEY=VALUE` lines |
| `validate`  | diagnostics (stderr only)   |
| `dump`      | parsed `KEY=VALUE` lines    |
| `delta`     | substituted `KEY=VALUE`     |
| `apply`     | full resulting env          |

## Stage contracts

### normalize(file) → records

File-level pass. Slurps the whole file before emitting any records, because
some passes (CRLF detection, continuation joining) require lookahead.

- Skip blank lines and comments
- Split on first `=`; emit `KEY=VALUE` without further validation
- Apply opt-in passes (see below); each pass is independently controlled

The key distinction: normalize does not validate key or value structure.
A line with an invalid key still gets emitted by normalize. Validation is
the next stage's job.

Each pass is controlled by an `ENVFILE_*` env var:

| Pass         | Env var                          | Values                | Default  | Formats        |
|--------------|----------------------------------|-----------------------|----------|----------------|
| BOM          | `ENVFILE_BOM`                    | `reject` `warn` `strip` | `warn`   | shell, compat  |
| CRLF         | `ENVFILE_CRLF`                   | `strip` `ignore`        | `ignore` | all            |
| NUL          | `ENVFILE_NUL`                    | `reject` `ignore`       | `reject` | all            |
| continuation | `ENVFILE_BACKSLASH_CONTINUATION` | `accept` `ignore`       | `ignore` | shell, compat  |

Pass details:

- **BOM** — UTF-8 BOM (`\xEF\xBB\xBF`) at byte 0: `warn` strips and warns;
  `strip` strips silently; `reject` treats the BOM as a file-error prepass.
  Shell
  and compat only — for `native`, BOM handling is unsupported at dispatch
  time, because native treats the file literally and does not apply BOM
  preprocessing.

- **CRLF** — `strip`: whole-file scan; convert only if *all* line endings are
  `\r\n`. Mixed or mid-line `\r` passes through unchanged. `ignore`: no
  conversion. Same behavior for all formats. The whole-file scan guards
  against corrupting `native` values that legitimately end in `\r`.

- **NUL** — `reject`: file-error prepass per file, before any other processing. `ignore`:
  pass through. `native` requires reject; `\0` is the OS-level env record
  separator and must be absent from file content.

- **continuation** — `accept`: a line ending in an odd number of backslashes
  is joined with the next; the trailing `\` and newline are consumed.
  Repeatable. Normalize does not process escape sequences — `\\` at end of
  line stays `\\`. Shell and compat only — for `native`, `\` is a valid
  value byte and `\n` is the record separator; setting
  `ENVFILE_BACKSLASH_CONTINUATION=accept` with `format=native` is a fatal
  dispatcher error.

### validate(records) → records

Line-level pass. Checks format-specific key/value rules.

- Emit `CODE: file:line` diagnostics to stderr
- Pass accepted records downstream; exit 1 on any error

### dump(records) → records

Apply intra-value transformations that require no external env.

- For `shell`: strip quote wrappers; handle `\\` and `\"` in double-quoted values
- For `native`: identity — no quoting layer exists
- Emit `KEY=value` to stdout

### delta(records, env) → bindings

Resolve variable references against the provided environment.

- For `shell`: double-quoted values substitute `$VAR`/`${VAR}`; single-quoted
  are fully literal
- For `native`: identity — values are literal bytes, no substitution
- Emit `KEY=resolved` to stdout

### apply(bindings, env) → new_env

Merge delta bindings into env (delta keys overwrite). Emit full resulting env,
sorted by key so fixture output is deterministic. Dispatcher/runtime shim vars
such as `ENVFILE_*` are excluded from the emitted environment.

## Implementation structure

The contract is behavioral, not structural. Impls own their internal
composition. The only requirement: `action=delta` output must be equivalent
to having run normalize, validate, and dump first.

The reference pattern (from `bin/envfile.awk`) is one function per stage,
each calling the next:

```
normalize(path) → validate(line) → dump(k, v, value) → delta(k, v, value) → apply()
```

Each function calls the next only when the requested action reaches that far.
This makes the pipeline structure visible at the call site and each stage
readable in isolation.

Typical shapes by implementation type:

- **awk**: single pass; `normalize()` slurps the file and feeds lines to
  `validate()`, which chains to `dump()`/`delta()` inline
- **compiled (C, Go, Rust, Zig)**: front-end owns file I/O and action routing;
  a backend (function, module, or linked object) handles per-line parsing;
  the front-end calls the appropriate emit path based on action
- **scripted (Python, Ruby)**: list of records passed through stage functions,
  or a generator/iterator chain

## Format matrix

| Stage     | shell                                   | native                               | compat (planned)              |
|-----------|-----------------------------------------|--------------------------------------|-------------------------------|
| normalize | BOM, CRLF (whole-file scan), NUL-reject, continuation | BOM, CRLF (whole-file scan), NUL-reject | BOM, CRLF (whole-file scan), NUL-reject, continuation |
| validate  | key charset, quoting rules              | non-empty name, literal values       | relaxed quoting               |
| dump      | strip quotes, `\\` `\"`                 | identity                             | backslash escapes             |
| delta     | subst in double-quoted only             | identity                             | full subst                    |
| apply     | merge                                   | merge                                | merge                         |

## Config surface

The dispatcher (`bin/envfile`) owns the full config surface. By the time an
impl is invoked, everything is resolved and forwarded as `ENVFILE_*` env vars.
Impls read env vars only — no ARGV parsing, no config file reading.

Three input domains, resolved in priority order (later wins):

1. `config=path` — native-format file; behavior knobs only
2. POSIX env vars — `ENVFILE_*` set in the caller's environment
3. ARGV `key=value` — routing and envfile channels only

Full `ENVFILE_*` var set forwarded to impls:

```
ENVFILE_FORMAT          shell|native|compat
ENVFILE_ACTION          normalize|validate|dump|delta|apply
ENVFILE_BOM                     reject|warn|strip
ENVFILE_CRLF                    strip|ignore
ENVFILE_NUL                     reject|ignore
ENVFILE_BACKSLASH_CONTINUATION  accept|ignore
```

`ENVFILE_LANGUAGE` is never forwarded — dispatcher-internal only.
`ENVFILE_*` control vars are dispatcher-only and are excluded from the
working/output environment used by `delta` and `apply`.

## Known limitations and open questions

**C front-end: normalize emits stripped values**
The C backend (`backend.c`, `backend.asm`) conflates parsing and validation
in a single pass, and strips quote wrappers inline. This means `action=normalize`
from the C impl emits validated, stripped records — identical to `dump` — rather
than raw pre-validation lines. Fixing this requires either a `raw` flag in the
backend interface, or a separate pre-validation normalize pass in the front-end.

**delta/apply not yet implemented in C**
The C front-end still stubs these actions with a clear error message. The awk
impl has full delta and apply support and serves as the behavior reference.
