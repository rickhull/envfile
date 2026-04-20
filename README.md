# envfile

`envfile` is a family of environment file formats under one banner:

* `native` - as direct an analogue to POSIX Environment as possible; newline-terminated rather than null-terminated
* `shell` - respects the upper/lower split from POSIX; upcased keys, quoted spaced values; does not accept anything that sh cannot reasonably source
* `compat` - broader compatibility with SystemD's `EnvironmentFile=` format (not shell-sourceable)

## Quick start

```sh
bin/lang status                    # what implementations are available?
bin/envfile format=shell action=validate shell/accepted/accepted.env
make all                           # build compiled implementations (skips missing toolchains)
just test                          # run the full test suite
```

No tools beyond `awk` are required. `make` uses whatever compilers are on
`PATH` and silently skips targets whose toolchain is absent.

Install [mise](https://mise.jdx.dev) and [just](https://github.com/casey/just)
for pinned tool versions and recipe-driven workflows, or use system tools
directly. See [docs/MISE.md](docs/MISE.md) for details.

## The tools

### `bin/envfile` — pipeline dispatcher

The primary interface. Resolves configuration, selects an implementation, and
execs it with all config forwarded as `ENVFILE_*` env vars.

```sh
bin/envfile format=shell action=dump shell/accepted/accepted.env
bin/envfile format=native action=validate native/accepted/ascii.env
bin/envfile format=shell action=normalize config=myconfig.env shell/normalize/bom.env
```

Configuration channels, resolved in priority order (later wins):

1. `config=path` — a native-format file; behavior knobs only (`BOM=`, `CRLF=`,
   `NUL=`, `BACKSLASH_CONTINUATION=`); everything else silently ignored
2. `ENVFILE_*` env vars — already in the caller's environment; fill gaps left
   by the config file
3. ARGV `key=value` — routing only: `format=`, `language=`, `action=`,
   `config=`, `env=`; behavior knobs are not accepted on ARGV

By the time an implementation is invoked, all configuration is resolved and
forwarded as env vars. Implementations read env vars only — no ARGV parsing,
no config file reading.

### `bin/bench` — benchmark dispatcher

Benchmarks implementations against fixture or corpus files. Always benches the
reference impl (awk) first as baseline.

```sh
bin/bench format=shell                          # all available impls
bin/bench format=native action=apply rs c       # only Rust and C
bin/bench format=shell files=corpus             # corpus instead of fixtures
```

The dispatcher parses `format=`, `action=`, `files=` from ARGV, sets
`BENCH_FORMAT`, `BENCH_ACTION`, `BENCH_FILES`, `BENCH_REFERENCE` as env vars,
then delegates to `bench.c` (or `bench.py`). Remaining ARGV is the impl filter:
bare language names or paths. Empty filter = discover all available
implementations.

### `bin/nullscan` — NUL byte scanner

Scans env files for NUL (`\0`) bytes. Used to identify files that require
`ENVFILE_NUL=ignore` or `reject` handling.

### `bin/lang` — language resolution

Query tool for language metadata and runnable implementation paths.

```sh
bin/lang status          # show all languages and tool availability
bin/lang awk envfile     # resolve runnable impl path for awk
bin/lang go which        # resolve tool path for go
bin/lang reference       # print the reference impl language (lowest-preference scripted)
```

See [docs/MISE.md](docs/MISE.md) for full resolution logic and mise
integration.

## Pipeline

Five actions form a pipeline: `normalize → validate → dump → delta → apply`.
Each action implicitly runs all prior stages. See [docs/PIPELINE.md](docs/PIPELINE.md)
for stage contracts, format matrix, config surface, and implementation guidance.

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
just test                          # shell + native against awk
just shell::verify c               # shell fixtures against C impl
just native::verify-normalize      # native normalize (8 fixture × mode combos)
just native::verify-apply          # native apply fixtures
just shell::check-bash             # semantic cross-check: bash must agree on accepted values
```

Regenerate golden files after intentional behavior changes, then review
the diff before committing:

```sh
just regen               # regenerate all golden files
just shell::regen        # shell only
just native::regen       # native only
```

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

## Build

```sh
make all          # build all compiled implementations + bench + nullscan
make c            # build just bin/envfile.c
make asm          # build bin/envfile.asm (C front-end + ASM backend)
make now          # fast compilation, unoptimized (-O0)
make fast         # optimized binaries (-O2, default)
make clean        # remove bin/ outputs and .make/ stamps
make status       # same as bin/lang status
```

## Corpus

`corpus/` holds sanitized real-world `.env` files used for validation and
benchmarking. No format is expected to accept any particular fraction.

```sh
just corpus::generate    # explore → filter → collect pipeline
```

## Additional docs

- [docs/PIPELINE.md](docs/PIPELINE.md) — full pipeline spec
- [docs/APPLY.md](docs/APPLY.md) — apply action semantics
- [docs/TERMINOLOGY.md](docs/TERMINOLOGY.md) — glossary
- [docs/STRATEGY.md](docs/STRATEGY.md) — adoption and standardization notes
- [docs/MISE.md](docs/MISE.md) — mise integration and bin/lang resolution
- [docs/NU.md](docs/NU.md) — Nushell implementation notes
- [docs/BENCHMARK_JITTER.md](docs/BENCHMARK_JITTER.md) — benchmarking noise notes
- [docs/BOM.md](docs/BOM.md) — BOM handling details
- [docs/ERRORS.md](docs/ERRORS.md) — error posture
- [docs/CORPUS.md](docs/CORPUS.md) — corpus generation pipeline

## License

MIT — see [LICENSE](LICENSE)
