# mise

[mise](https://mise.jdx.dev/) manages tool versions for this repo. It is
optional — contributors without it can use system-installed tooling — but it
provides pinned, reproducible versions for everyone who has it.

## .mise.toml

Tool versions are pinned in `.mise.toml`:

```toml
[tools]
just                   = "latest"
go                     = "latest"
zig                    = "latest"
rust                   = "latest"
"aqua:nushell/nushell" = "latest"
node                   = "latest"
bun                    = "latest"
deno                   = "latest"
ruby                   = "latest"
python                 = "latest"
```

`just` itself is pinned here. If mise is not installed, any recent `just`
should work.

## What is not in mise

`nasm` is not managed by mise. It is expected to be installed via the system
package manager (`pacman -S nasm`, `apt install nasm`, etc.). The asm
implementations will be skipped if `nasm` is absent.

`cc` (C compiler) is similarly a system dependency, not a mise tool.

## bin/lang

`bin/lang` is a POSIX sh script that reads `languages.env` and reports
language metadata plus runnable implementation paths.

### Query mode

```
bin/lang <lang> [<field>]
```

Prints one field value for a language entry. With no field, it prints every
field for the language. Raw fields come directly from `languages.env`
(`execution`, `build`, `exec`, `availability`, `mise`, `extension`). Two
resolved fields are also available:

| field       | value                                    |
|-------------|------------------------------------------|
| `which`     | resolved executable path on `PATH`       |
| `envfile`   | runnable repo-local implementation path  |

Examples:

```sh
bin/lang go which         # → /usr/bin/go
bin/lang zig envfile      # → bin/envfile.zig
bin/lang bun mise         # → available
```

`bin/lang` does not shell out through `mise exec`. The `mise` metadata is
used for availability reporting and documentation, while actual resolution
is driven by the executable currently on `PATH` and, for compiled targets,
an on-demand `make` build.

### Resolution logic

For a language entry in `languages.env`:

1. `command -v <tool>` — PATH check only, no fork
2. If that fails: unavailable

For languages without a `mise` field (`cc`, `nasm`, `awk`, `bash`, etc.),
the same PATH-only resolution applies.

This means contributors with mise can opt into pinned versions via the
surrounding toolchain, but `bin/lang` itself stays cheap and local. For
scripted targets, missing runtimes are reported as unavailable. For compiled
targets, missing binaries trigger an on-demand build; if the build tool is
absent, that language is also reported as unavailable.
