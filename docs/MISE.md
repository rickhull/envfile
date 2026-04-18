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

`bin/lang` is a POSIX sh script that bridges `languages.env` with the
runtime environment. It has two modes.

### Query mode

```
bin/lang <lang> <field>
```

Prints one field value for a language entry. Raw fields come directly from
`languages.env` (`execution`, `build`, `exec`, `mise`, `check_args`). Two
resolved fields are also available:

| field       | value                                    |
|-------------|------------------------------------------|
| `available` | `yes` or `no` (probed at call time)      |
| `invoke`    | full resolved command, e.g. `go` or `mise exec -- zig` |

Examples:

```sh
bin/lang go invoke        # → go
bin/lang zig available    # → yes
bin/lang bun mise         # → available
```

### Exec mode

```
bin/lang <lang> -- <args...>
```

Resolves the tool and execs it directly, passing `<args...>` unchanged. Used
by the Makefile and `impl.just` so build rules and activation checks do not
hard-code `mise exec --`.

Examples:

```sh
bin/lang go   -- version
bin/lang rust -- --version
bin/lang zig  -- build-exe src/zig/main.zig ...
```

### Resolution logic

For a language with `mise=available` in `languages.env`:

1. `command -v <tool>` — PATH check only, no fork
2. If that fails, try: `mise exec -- <tool> <check_args>`
3. If both fail: unavailable

For languages without a `mise` field (`cc`, `nasm`, `awk`, `bash`, etc.):
naked invoke only, no fallback.

This means contributors with mise get pinned versions; contributors without
it fall through to whatever is on their PATH. The worst-case probe (both
checks fail) takes ~30ms, which is acceptable given that it only occurs for
unavailable tools.

