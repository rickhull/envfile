set shell := ["bash", "-cu"]

# Validate the native starter fixtures with the native dispatcher path.
validate:
  { bin/nullscan native/accepted/ascii.env >/dev/null && bin/envfile format=native action=validate native/accepted/ascii.env; }
  { bin/nullscan native/accepted/utf8.env >/dev/null && bin/envfile format=native action=validate native/accepted/utf8.env; }
  { bin/nullscan native/accepted/binary.env >/dev/null && bin/envfile format=native action=validate native/accepted/binary.env; }
  { bin/nullscan native/rejected/ascii.env >/dev/null && bin/envfile format=native action=validate native/rejected/ascii.env; } || true
  { bin/nullscan native/rejected/utf8.env >/dev/null && bin/envfile format=native action=validate native/rejected/utf8.env; } || true
  { bin/nullscan native/rejected/binary.env >/dev/null && bin/envfile format=native action=validate native/rejected/binary.env; } || true

# Normalize the native starter fixtures to canonical KEY=VALUE lines.
normalize:
  { bin/nullscan native/accepted/ascii.env >/dev/null && bin/envfile format=native action=normalize native/accepted/ascii.env; }
  { bin/nullscan native/accepted/utf8.env >/dev/null && bin/envfile format=native action=normalize native/accepted/utf8.env; }
  { bin/nullscan native/accepted/binary.env >/dev/null && bin/envfile format=native action=normalize native/accepted/binary.env; }
  { bin/nullscan native/rejected/ascii.env >/dev/null && bin/envfile format=native action=normalize native/rejected/ascii.env; } || true
  { bin/nullscan native/rejected/utf8.env >/dev/null && bin/envfile format=native action=normalize native/rejected/utf8.env; } || true
  { bin/nullscan native/rejected/binary.env >/dev/null && bin/envfile format=native action=normalize native/rejected/binary.env; } || true

# Regenerate native validate-mode references.
generate-reference:
  { bin/nullscan native/accepted/ascii.env >/dev/null && bin/envfile format=native action=validate native/accepted/ascii.env; } > native/accepted/ascii.txt 2>&1
  { bin/nullscan native/accepted/utf8.env >/dev/null && bin/envfile format=native action=validate native/accepted/utf8.env; } > native/accepted/utf8.txt 2>&1
  { bin/nullscan native/accepted/binary.env >/dev/null && bin/envfile format=native action=validate native/accepted/binary.env; } > native/accepted/binary.txt 2>&1
  { bin/nullscan native/rejected/ascii.env >/dev/null && bin/envfile format=native action=validate native/rejected/ascii.env; } > native/rejected/ascii.txt 2>&1 || true
  { bin/nullscan native/rejected/utf8.env >/dev/null && bin/envfile format=native action=validate native/rejected/utf8.env; } > native/rejected/utf8.txt 2>&1 || true
  { bin/nullscan native/rejected/binary.env >/dev/null && bin/envfile format=native action=validate native/rejected/binary.env; } > native/rejected/binary.txt 2>&1 || true

# Verify implementations against the native starter references.
verify *args:
  #!/usr/bin/env bash
  set -uo pipefail
  targets=({{args}})
  [[ ${#targets[@]} -eq 0 ]] && targets=(bin/envfile bin/envfile.asm bin/envfile.awk bin/envfile.bash bin/envfile.bun.js bin/envfile.deno.js bin/envfile.go bin/envfile.node.js bin/envfile.nu bin/envfile.pl bin/envfile.py bin/envfile.rb bin/envfile.sh bin/envfile.zig)
  ok=1
  for impl in "${targets[@]}"; do
    [[ -x "$impl" ]] || { echo "skip: $impl (not executable)"; continue; }
    just native::do_verify "$impl" || ok=0
  done
  [[ $ok -eq 1 ]]

# Compare a single implementation against all native fixtures.
[private]
do_verify impl:
  #!/usr/bin/env bash
  set -uo pipefail
  ok=1
  for f in accepted/ascii accepted/utf8 rejected/ascii rejected/utf8 lame; do
    case {{impl}} in
      bin/envfile)
        got=$({{impl}} format=native action=validate native/${f}.env 2>&1 || true)
        ;;
      *)
        got=$(ENVFILE_FORMAT=native ENVFILE_ACTION=validate {{impl}} native/${f}.env 2>&1 || true)
        ;;
    esac
    ref=$(cat native/${f}.txt)
    if [[ "$got" != "$ref" ]]; then
      echo "FAIL: {{impl}} native/${f}.env"
      diff <(echo "$ref") <(echo "$got")
      ok=0
    else
      echo "ok:   {{impl}} native/${f}.env"
    fi
    # normalize check: error-free fixtures must roundtrip byte-for-byte
    if echo "$ref" | grep -q '^0 checked, 0 errors'; then
      continue  # empty file, nothing to normalize
    fi
    if echo "$ref" | grep -q ', 0 errors, '; then
      tmp=$(mktemp)
      trap "rm -f $tmp" RETURN
      case {{impl}} in
        bin/envfile)
          {{impl}} format=native action=normalize native/${f}.env > "$tmp" 2>/dev/null
          ;;
        *)
          ENVFILE_FORMAT=native ENVFILE_ACTION=normalize {{impl}} native/${f}.env > "$tmp" 2>/dev/null
          ;;
      esac
      if ! diff -q native/${f}.env "$tmp" >/dev/null 2>&1; then
        echo "FAIL: {{impl}} native/${f}.env normalize"
        diff native/${f}.env "$tmp"
        ok=0
      fi
      rm -f "$tmp"
    fi
  done
  [[ $ok -eq 1 ]]
