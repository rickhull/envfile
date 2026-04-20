# envfile

`envfile` is a family of environment file formats under one banner.

Current scopes:

- `shell/` — shell-oriented format with quoting discipline; no interpolation, no `export` prefix
- `native/` — POSIX-native, byte-oriented format (`KEY=VALUE`, `\n`-terminated, three special bytes: `=`, `\n`, `\0`)
- `compat/` — reserved for a possible future relaxed format
- `corpus/` — sanitized real-world `.env` files shared across formats

## Pipeline

Five actions form a pipeline: `normalize → validate → dump → delta → apply`.
Each action implicitly runs all prior stages. See [docs/PIPELINE.md](docs/PIPELINE.md)
for stage contracts, format matrix, config surface, and implementation guidance.

Normalize pass configuration (all formats unless noted):

| Variable | Values | Default | Formats |
|---|---|---|---|
| `ENVFILE_BOM` | `literal` `strip` `reject` | `strip` | shell, compat |
| `ENVFILE_CRLF` | `strip` `ignore` | `ignore` | all |
| `ENVFILE_NUL` | `reject` `ignore` | `reject` | all |
| `ENVFILE_BACKSLASH_CONTINUATION` | `accept` `ignore` | `ignore` | shell, compat |

`ENVFILE_CRLF=strip` uses a whole-file scan: strips `\r` only if every line
ends `\r\n`; mixed files are left untouched.

## Testing

`bin/envfile.awk` is the canonical reference implementation. All other
implementations are verified against its output. It runs with `LC_ALL=C` (via
shebang) so byte-level behavior — BOM detection, high-byte handling — is
locale-independent.

Verification is fixture-driven. Each format module owns its full fixture tree:

```
shell/accepted/     — valid shell assignments
shell/rejected/     — invalid shell assignments (every line triggers an error)
shell/mixed/        — interleaved valid and invalid lines
shell/normalize/    — normalize-pass inputs (BOM, CRLF, NUL, continuation)
native/accepted/    — valid native assignments
native/rejected/    — invalid native assignments
native/normalize/   — normalize-pass inputs (CRLF, NUL)
native/delta/       — delta-action inputs and expected outputs
native/apply/       — apply-action inputs and expected outputs
```

Reference outputs are sidecar files committed next to each fixture:

- `.err` — expected stderr (diagnostics + summary line `N checked, N errors`)
- `.out` — expected stdout (emitted records)
- **Absent file = assertion of empty content.** A missing `.out` means stdout
  must be empty.

For normalize fixtures, which require different `ENVFILE_*` options per test
case, sidecars are named `<base>.<mode-label>.err` and `<base>.<mode-label>.out`:

```
shell/normalize/bom.BOM=literal.err
shell/normalize/crlf.CRLF=strip.out
native/normalize/nul.NUL=ignore.out
```

Run the full verification suite:

```sh
just shell::verify              # all shell fixtures: accepted, rejected, mixed
just shell::verify-normalize    # shell normalize fixtures (11 fixture × mode combos)
just native::verify             # all native fixtures: accepted, rejected
just native::verify-normalize   # native normalize fixtures (8 fixture × mode combos)
just native::verify-apply       # native apply fixtures
just shell::check-bash          # semantic cross-check: bash must agree on accepted values
```

All recipes accept an optional implementation argument:

```sh
just shell::verify c
just native::verify-normalize awk c
```

Regenerate golden files after intentional behavior changes, then review
the diff before committing:

```sh
just regen               # regenerate all golden files
just shell::regen        # shell only
just native::regen       # native only
just native::regen-apply # native apply only
```

## Quick start

```sh
just impls         # check which implementations are available
make all           # build all compiled implementations
just test          # run the full test suite against the reference implementation
```

## Dispatcher

`bin/envfile` is the POSIX `sh` entry point and the primary interface to the
repo. It resolves configuration, selects an implementation, and execs it with
all config forwarded as `ENVFILE_*` env vars.

```sh
bin/envfile format=shell action=dump shell/accepted/accepted.env
bin/envfile format=native action=validate native/accepted/ascii.env
bin/envfile format=shell action=normalize config=myconfig.env shell/normalize/bom.env
```

**Configuration channels**, resolved in priority order (later wins):

1. `config=path` — a native-format file; behavior knobs only (`BOM=`, `CRLF=`,
   `NUL=`, `BACKSLASH_CONTINUATION=`); everything else silently ignored
2. `ENVFILE_*` env vars — already in the caller's environment; fill gaps left
   by the config file
3. ARGV `key=value` — routing only: `format=`, `language=`, `action=`,
   `config=`, `env=`; behavior knobs are not accepted on ARGV

By the time an implementation is invoked, all configuration is resolved and
forwarded as env vars. Implementations read env vars only — no ARGV parsing,
no config file reading.

Format-gating: `ENVFILE_BOM` values other than `literal`, and
`ENVFILE_BACKSLASH_CONTINUATION=accept`, are fatal errors for `format=native`.

Default implementation search order: `awk`, then `perl`/`bash`/`python`/`sh`
for shell; `awk`, `c`, `go`, `zig`, `bash`, `sh`, `perl` for native.

## Implementations

Each implementation lives at `bin/envfile.<suffix>` (interpreted) or is built
from `src/<language>/` (compiled):

| Suffix | Language | Type |
|---|---|---|
| `.awk` | AWK | interpreted — reference impl |
| `.c` | C | compiled — C backend |
| `.asm` | C + x86-64 ASM | compiled — ASM backend |
| `.go` | Go | compiled |
| `.rs` | Rust | compiled |
| `.zig` | Zig | compiled |
| `.py` | Python | interpreted |
| `.pl` | Perl | interpreted |
| `.rb` | Ruby | interpreted |
| `.bash` | Bash | interpreted |
| `.sh` | POSIX sh | interpreted |
| `.nu` | Nushell | interpreted |
| `.node.js` | Node.js | interpreted |
| `.bun.js` | Bun | interpreted |
| `.deno.js` | Deno | interpreted |

The C build uses a pluggable backend: `src/c/envfile.c` is the shared
front-end; `src/c/backend.c` or `src/c/backend.asm` is selected at link time.

`bin/lang <lang> envfile` resolves a runnable repo implementation for a
language, building compiled targets on demand and treating missing runtimes as
unavailable.

## Build

```sh
make all          # build all compiled implementations
make c            # build just bin/envfile.c
make asm          # build bin/envfile.asm (C front-end + ASM backend)
make now          # fast compilation, unoptimized (-O0)
make fast         # optimized binaries (-O2, default)
make clean        # remove bin/ outputs and .make/ stamps
```

## Benchmark

`bin/bench` and `bin/nullscan` are built by `make all`. To build individually:
`make bench`, `make nullscan`.

```sh
just bench::run       # run benchmark binary
just bench::shell     # shell-format benchmarks
just bench::native    # native-format benchmarks
just bench::corpus    # benchmark over corpus files
```

## Corpus

`corpus/` holds sanitized real-world `.env` files used for validation and
benchmarking. No format is expected to accept any particular fraction.

```sh
just corpus::generate    # explore → filter → collect pipeline
```

## Additional docs

- [docs/PIPELINE.md](docs/PIPELINE.md) — full pipeline spec
- [docs/TERMINOLOGY.md](docs/TERMINOLOGY.md) — glossary
- [docs/STRATEGY.md](docs/STRATEGY.md) — adoption and standardization notes
- [docs/BENCHMARK_JITTER.md](docs/BENCHMARK_JITTER.md) — benchmarking noise notes

## License

MIT — see [LICENSE](LICENSE)
