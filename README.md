# envfile

`envfile` is a family of environment file formats under one banner.

Current scopes:

- `strict/` — the mature strict format and multi-implementation validator suite
- `native/` — a planned POSIX-native, byte-oriented format
- `compat/` — reserved for a possible future relaxed format
- `corpus/` — a top-level real-world corpus shared across formats

Shared implementation infrastructure currently lives at the repo root:

- `bin/` — one executable entry per implementation
- `src/` — implementation sources
- `Makefile` — primary native build graph with incremental rebuilds
- `make` — `just` wrapper for `make all`
- `now` — `just` wrapper for `make now` (`snappy` builds)
- `fast` — `just` wrapper for `make fast` (optimized binaries)
- `nullscan` — awk file-gate helper; `make nullscan` can overwrite it with the C build locally
- `fresh` — `just` wrapper for `make fresh` (restores bootstrap symlinks)
- `clean` — `just` wrapper for `make clean`
- `impl.just` — shared implementation activation/probing
- `bench.just` — shared benchmark helpers

The Makefile also exposes `make now` and `make fast` as mode selectors for the
same build graph. `fast` is the default. Mode changes update the cached build
stamps under `.make/` and rebuild the final `bin/` outputs when the selected
flags differ. `now` biases toward faster compilation; `fast` biases toward
optimized binaries.

The current center of gravity is `strict/`. `native/` is being prepared as its
own workspace rather than being forced into strict’s assumptions too early.

Committed validator outputs are code-first: `ERROR_*` values are emitted as
`CODE: file:line`.

## Repo shape

- [strict/README.md](strict/README.md) — strict format, implementations, and workflow
- [strict.just](strict.just) — strict workflow entry point
- [native/README.md](native/README.md) — native format workspace
- [native.just](native.just) — native workflow entry point
- [compat/README.md](compat/README.md) — compat placeholder
- [compat.just](compat.just) — compat placeholder entry point
- [corpus/README.md](corpus/README.md) — shared real-world corpus pipeline

## Quick start

Strict:

```sh
just impl::activate
just make
just strict::validate
just strict::normalize
just strict::verify
```

Corpus:

```sh
just corpus::generate
```

Bench:

```sh
make nullscan
just bench::run
just bench::strict
just bench::native
just bench::corpus
just bench::strict_corpus
just bench::native_corpus
just bench::nullscan
```

## Implementation naming

Implementation entries are being normalized around a derived naming rule.

The top-level `bin/envfile` is the general POSIX `sh` entry point. It parses
leading `format=`, `language=`, and `action=` key/value arguments, defaults to
`format=strict` and `action=validate`, and uses `awk` by default with `perl`,
`bash`, `python`, and `sh` as fallback validators when no language is
specified.

It does not fundamentally depend on `mise` or any other package manager.
Some implementation backends may use `mise` for tool availability, but the
dispatcher itself stays self-contained.

Right now, `native` routes through the native-capable backends, with `awk`
first, and `perl`, `bash`, and `sh` as pragmatic line-oriented options;
`compat` still routes to the strict baseline.

Example:

```sh
bin/envfile format=strict action=normalize strict/accepted.env
```

The executable suffix is derived by a small built-in table:

- `bash` -> `bin/envfile.bash`
- `python` -> `bin/envfile.py`
- `perl` -> `bin/envfile.pl`
- `nushell` -> `bin/envfile.nu`
- `sh` -> `bin/envfile.sh`
- `ruby` -> `bin/envfile.rb`
- `rust` -> `bin/envfile.rs`

Qualified language keys remain qualified:

- `node.js` -> `bin/envfile.node.js`
- `bun.js` -> `bin/envfile.bun.js`
- `deno.js` -> `bin/envfile.deno.js`

Binary entry:

```text
bin/envfile.<suffix>
```

Source location:

```text
runtime = interpreted -> same as binary entry
runtime = native      -> src/<language>/
```

Examples for binary entry:

- `bin/envfile.bash`
- `bin/envfile.py`
- `bin/envfile.pl`
- `bin/envfile.nu`
- `bin/envfile.rb`
- `bin/envfile.c`
- `bin/envfile.rs`
- `bin/envfile.node.js`

The C build is the readable reference path; `bin/envfile.asm` is the optional
asm-backed variant built from the same repo contract in `src/c/`.

For native implementations, source location is derived from the same key under
`src/`. For interpreted implementations, the entry script is itself the
source.

`impl.just` stays intentionally explicit so the activation path does not need
to parse the registry a second time.

## Implementation Shape

The C path is structured as a small front-end with a swappable backend:

- `src/c/envfile.c` owns file I/O, buffering, counting, and output formatting.
- `src/c/backend.c` is the default C parser backend.
- `src/c/backend.asm` is the optional backend that is linked in for
  `bin/envfile.asm`.

This is the repo's reference example of "pluggable vibes": one stable C
surface, with the parser backend chosen at build/link time instead of by source
replacement.

## What strict is

`.env` is not a standard. Shells, Docker, `dotenv` libraries, Kubernetes
secret loaders, and CI systems all parse it differently.

`envfile/strict` defines a strict, minimal subset: one assignment per line, no
interpolation, no variable references, no command substitution, no `export`
prefix. It is backed by multiple independent implementations and committed
reference outputs.

For the full strict format and workflow, see [strict/README.md](strict/README.md).

## What native is

`envfile/native` aims to represent a POSIX-style environment as directly as
possible: literal `KEY=VALUE` records, `\n`-terminated lines, no shell
interpretation layer, and only three special bytes: `=`, `\n`, and `\0`.
File-level NUL rejection is handled before the parser runs.

For the current draft, see [native/README.md](native/README.md).

## Corpus

`corpus/` is not owned by `strict`. It is shared input material: sanitized
real-world files used to observe validator behavior and to benchmark against
larger, more varied inputs.

`strict` is currently used for corpus acceptance, but no format is expected to
accept any particular fraction of the corpus.

See [corpus/README.md](corpus/README.md).

## Additional docs

- [docs/STRATEGY.md](docs/STRATEGY.md) — adoption and standardization strategy notes
- [docs/DATA_GATHERING.md](docs/DATA_GATHERING.md) — ideas for collecting real-world env files
- [docs/BENCHMARK_JITTER.md](docs/BENCHMARK_JITTER.md) — benchmarking noise and mitigation
- [docs/planning/COLLAPSE_ALGO.md](docs/planning/COLLAPSE_ALGO.md) — corpus collapse algorithm notes

## Tooling note

`strict/` owns the strict format and fixtures. `bin/` and `src/` are shared
repo-level implementation infrastructure, so a single implementation entry can
eventually handle `strict`, `native`, or `compat`.

## License

MIT
