# Nu implementation notes

`bin/envfile.nu` is the Nushell implementation of the envfile pipeline. It
handles both `shell` and `native` formats across all five actions.

## Structure

The file is organized as a set of focused helper functions feeding into
`process_file`, which is called once per input path from `main`.

```
main
  └─ process_file (per path)
       ├─ split_lines_text / split_lines_bin   — line splitting
       ├─ is_continuation                      — backslash continuation test
       ├─ unquote_shell_value                  — quote stripping / validation
       ├─ resolve_var                          — single variable lookup
       └─ subst_value                          — full $VAR / ${VAR} expansion
```

`seed_env_map` is called once from `main` before the file loop when
`action=delta` or `action=apply`. It snapshots the current environment into a
plain record for substitution, excluding all `ENVFILE_*` keys.

## Byte vs string duality

Nu's `open --raw` returns a `string` for files it can decode as UTF-8 and a
`binary` for everything else. The two types have different APIs and the
implementation branches on them throughout.

`process_file` detects the type with `describe`:

```nu
let is_binary = (($file_text | describe) == "binary")
```

Binary files are split on the `LF` byte (`bytes split`), each chunk decoded as
ISO-8859-1, and then treated as strings for the remainder of processing. This
is a byte-preserving round-trip: ISO-8859-1 maps bytes 0x00–0xFF to the same
codepoints, so no information is lost and string operations behave correctly.
Text files are split on `"\n"` directly.

Both paths strip a trailing empty element produced by a final newline, since
`split row "\n"` and `bytes split` both produce an empty tail in that case.

## BOM detection and stripping

The BOM check encodes the first line to UTF-8 bytes and tests for the prefix
`0xEF 0xBB 0xBF`:

```nu
($lines | get 0 | encode utf-8) | bytes starts-with $BOM_BYTES
```

Stripping uses the same round-trip — slice off the first 3 bytes then decode:

```nu
$lines | update 0 { encode utf-8 | bytes at 3.. | decode utf-8 }
```

The `str substring 1..` (codepoint-level) shortcut does not work here because
Nu's text pipeline decodes the file as UTF-8 but the BOM bytes arrive as
latin-1 mojibake rather than the single U+FEFF codepoint, so the codepoint
index of the BOM is 3, not 1. The byte round-trip is intentional.

## Variable substitution

`subst_value` is a character-level scanner that handles `$NAME` and `${NAME}`
references. It is implemented as an imperative while loop because the logic is
genuinely stateful: each iteration consumes a variable-length prefix of `$rest`
and advances the scan position. A pipeline or `reduce` would not simplify this.

`resolve_var` handles the lookup for both reference styles. It uses `get -o`
(optional get) to distinguish a missing key from an empty-string value:

```nu
let got = ($env_map | get -o $name)
if ($got | is-empty) { ... }   # key absent
```

When the value is present, it may be either a plain string or a single-element
list (Nu's `$env` can return list-typed entries). The type dispatch handles
this:

```nu
let val = if (($got | describe) == "string") { $got } else { $got | first }
```

This is a pragmatic workaround for Nu's typed environment — there is no
cleaner way to extract a scalar from a value whose type is not known in advance.

## Environment seeding

`seed_env_map` converts `$env` (a Nu record) into a flat `record<string,
string>` for substitution. It excludes `ENVFILE_*` keys and normalizes typed
values:

- `list<*>` entries are joined with `:` (the POSIX `PATH`-style convention)
- All other entries are coerced with `into string`
- Entries that cannot be coerced (e.g. records, closures) are silently dropped

The pipeline uses `compact` to remove the `null` entries produced by skipped
values, then `transpose --header-row --as-record` to convert the key/value
table back to a record.

## Continuation joining

`ENVFILE_BACKSLASH_CONTINUATION=accept` joins lines whose trailing backslash
run has odd length (one unescaped `\`). The test uses a regex to extract the
trailing run:

```nu
let trail = ($line | parse --regex '(\\+)$')
($trail.0.capture0 | str length) mod 2 == 1
```

The joining loop is an imperative while loop with explicit index arithmetic
because it requires lookahead: after consuming the continuation marker, the
next line may itself be a continuation, requiring another iteration before
emitting the joined record. This is one of two while loops in the file that
cannot be straightforwardly expressed as a pipeline.

## CRLF stripping

`ENVFILE_CRLF=strip` applies only when every line ends with `\r`. This
whole-file guard prevents corrupting `native` values that legitimately contain
a trailing `\r`. The check uses `all`:

```nu
let all_crlf = ($lines | is-not-empty) and ($lines | all { str ends-with "\r" })
```

## Known limitations

- Non-string, non-list typed `$env` entries (records, closures, etc.) are
  silently ignored by `seed_env_map` rather than canonicalized.
- `get -o` returns `null` for both absent keys and keys with a `null` value;
  a key explicitly set to `null` in `env_map` would be treated as unbound.
  In practice this cannot arise since all seeded and accumulated values are
  strings.
