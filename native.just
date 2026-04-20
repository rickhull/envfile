set shell := ["bash", "-cu"]

# Validate the native starter fixtures with the native dispatcher path.
validate:
  #!/usr/bin/env bash
  set -uo pipefail
  while IFS= read -r f; do
    { LC_ALL=C bin/nullscan "$f" >/dev/null && bin/envfile format=native action=validate "$f"; } || true
  done < <(find native/accepted native/rejected -name "*.env" | sort)

# Dump the native starter fixtures to canonical KEY=VALUE lines.
dump:
  #!/usr/bin/env bash
  set -uo pipefail
  while IFS= read -r f; do
    { LC_ALL=C bin/nullscan "$f" >/dev/null && bin/envfile format=native action=dump "$f"; } || true
  done < <(find native/accepted native/rejected -name "*.env" | sort)

# Regenerate native normalize golden files from AWK (review diff before committing).
regen-normalize:
  #!/usr/bin/env bash
  set -uo pipefail
  while IFS=$'\t' read -r fixture mode envvars; do
    base="${fixture%.env}"
    env $envvars \
      bin/envfile format=native action=normalize "$fixture" \
      > "${base}.${mode}.out" 2>"${base}.${mode}.err" || true
    [[ -s "${base}.${mode}.out" ]] || rm -f "${base}.${mode}.out"
    echo "wrote: ${base}.${mode}.{err,out}"
  done < <(just native::_normalize-table)

# Regenerate all native golden files (review diff before committing).
regen: regen-normalize regen-delta
  #!/usr/bin/env bash
  set -uo pipefail
  while IFS= read -r f; do
    base="${f%.env}"
    { LC_ALL=C bin/nullscan "$f" >/dev/null && bin/envfile format=native action=validate "$f"; } \
      > "${base}.err" 2>&1 || true
  done < <(find native/accepted native/rejected -name "*.env" | sort)

# Regenerate native delta golden files against standard.env (review diff before committing).
regen-delta:
  env -i $(grep -v '^#' standard.env | grep -v '^$' | tr '\n' ' ') \
    bin/envfile format=native action=delta native/delta/basic.env \
    > native/delta/basic.out 2> native/delta/basic.err; true

# Run delta against standard.env and show output.
delta:
  env -i $(grep -v '^#' standard.env | grep -v '^$' | tr '\n' ' ') \
    bin/envfile format=native action=delta native/delta/basic.env

# Regenerate native apply golden files against a fixed synthetic env.
regen-apply:
  #!/usr/bin/env bash
  set -uo pipefail
  while IFS=$'\t' read -r fixture envvars keys; do
    base="${fixture%.env}"
    tmp_out=$(mktemp)
    tmp_err=$(mktemp)
    env -i $envvars \
      bin/envfile format=native action=apply "$fixture" \
      > "$tmp_out" 2> "$tmp_err" || true
    awk -F= -v keys="$keys" '
      BEGIN {
        n = split(keys, want, /[[:space:]]+/)
        for (i = 1; i <= n; i++) if (want[i] != "") seen[want[i]] = 1
      }
      ($1 in seen) { print }
    ' "$tmp_out" > "${base}.out"
    mv "$tmp_err" "${base}.err"
    rm -f "$tmp_out"
    echo "wrote: ${base}.{err,out}"
  done < <(just native::_apply-table)

# Run apply against a fixed synthetic env and show output.
apply:
  env -i A=1 B=2 HOME=/home/user PATH=/usr/local/bin:/usr/bin:/bin \
    bin/envfile format=native action=apply native/apply/basic.env

# Verify normalize passes against native reference sidecars.
verify-normalize *args:
  #!/usr/bin/env bash
  set -uo pipefail
  raw=({{args}})
  if [[ ${#raw[@]} -eq 0 ]]; then
    targets=(bin/envfile)
  else
    targets=()
    for arg in "${raw[@]}"; do
      if [[ -x "$arg" ]]; then targets+=("$arg")
      else path=$(bin/lang "$arg" envfile 2>/dev/null) || { echo "unknown impl: $arg"; exit 1; }; targets+=("$path")
      fi
    done
  fi
  ok=1
  tmp_norm_out=$(mktemp)
  tmp_norm_err=$(mktemp)
  trap 'rm -f "$tmp_norm_out" "$tmp_norm_err"' EXIT
  for impl in "${targets[@]}"; do
    [[ -x "$impl" ]] || { echo "skip: $impl (not executable)"; continue; }
    while IFS=$'\t' read -r fixture mode envvars; do
      base="${fixture%.env}"
      env ENVFILE_FORMAT=native ENVFILE_ACTION=normalize $envvars \
        "$impl" "$fixture" >"$tmp_norm_out" 2>"$tmp_norm_err" || true
      fail=0
      if ! diff -q "${base}.${mode}.err" "$tmp_norm_err" >/dev/null 2>&1; then
        echo "FAIL (stderr): $impl $fixture [$mode]"
        diff "${base}.${mode}.err" "$tmp_norm_err"
        fail=1
      fi
      ref_out="${base}.${mode}.out"
      if [[ -f "$ref_out" ]]; then
        if ! diff -q "$ref_out" "$tmp_norm_out" >/dev/null 2>&1; then
          echo "FAIL (stdout): $impl $fixture [$mode]"
          diff "$ref_out" "$tmp_norm_out"
          fail=1
        fi
      elif [[ -s "$tmp_norm_out" ]]; then
        echo "FAIL (stdout): $impl $fixture [$mode] — unexpected output"
        cat "$tmp_norm_out"
        fail=1
      fi
      [[ $fail -eq 0 ]] && echo "ok:   $impl $fixture [$mode]"
      [[ $fail -eq 0 ]] || ok=0
    done < <(just native::_normalize-table)
  done
  [[ $ok -eq 1 ]]

# Verify implementations against the native starter references.
verify *args:
  #!/usr/bin/env bash
  set -uo pipefail
  raw=({{args}})
  if [[ ${#raw[@]} -eq 0 ]]; then
    targets=(bin/envfile)
    while IFS= read -r lang; do
      path=$(bin/lang "$lang" envfile 2>/dev/null) || continue
      [[ -x "$path" ]] || continue
      targets+=("$path")
    done < <(bin/lang list)
  else
    targets=()
    for arg in "${raw[@]}"; do
      if [[ -x "$arg" ]]; then targets+=("$arg")
      else path=$(bin/lang "$arg" envfile 2>/dev/null) || { echo "unknown impl: $arg"; exit 1; }; targets+=("$path")
      fi
    done
  fi
  ok=1
  for impl in "${targets[@]}"; do
    [[ -x "$impl" ]] || { echo "skip: $impl (not executable)"; continue; }
    just native::do_verify "$impl" || ok=0
  done
  [[ $ok -eq 1 ]]

# Compare a single implementation against all native fixtures with sidecars.
# delta/ and lame.env are handled by dedicated recipes and excluded here.
[private]
do_verify impl:
  #!/usr/bin/env bash
  set -uo pipefail
  ok=1
  tmp_got_err=$(mktemp)
  trap 'rm -f "$tmp_got_err"' EXIT
  while IFS= read -r envfile; do
    base="${envfile%.env}"
    ref_err=$(cat "${base}.err" 2>/dev/null || true)
    ref_out=$(cat "${base}.out" 2>/dev/null || true)
    [[ -z "$ref_err" && -z "$ref_out" ]] && continue
    # nullscan gates NUL-containing files before the impl sees them
    if ! LC_ALL=C bin/nullscan "$envfile" >/dev/null 2>"$tmp_got_err"; then
      got_out=""
    else
      case {{impl}} in
        bin/envfile)
          got_out=$({{impl}} format=native action=validate "$envfile" 2>"$tmp_got_err" || true)
          ;;
        *)
          got_out=$(ENVFILE_FORMAT=native ENVFILE_ACTION=validate {{impl}} "$envfile" 2>"$tmp_got_err" || true)
          ;;
      esac
    fi
    got_err=$(cat "$tmp_got_err")
    fail=0
    if [[ "$got_err" != "$ref_err" ]]; then
      echo "FAIL (stderr): {{impl}} $envfile"
      diff <(echo "$ref_err") <(echo "$got_err")
      fail=1
    fi
    if [[ "$got_out" != "$ref_out" ]]; then
      echo "FAIL (stdout): {{impl}} $envfile"
      diff <(echo "$ref_out") <(echo "$got_out")
      fail=1
    fi
    [[ $fail -eq 0 ]] && echo "ok:   {{impl}} $envfile"
    [[ $fail -eq 0 ]] || ok=0
  done < <(find native/accepted native/rejected -name "*.env" | sort)
  [[ $ok -eq 1 ]]

# Verify apply fixtures against the native reference output.
# Compare only the fixture's explicit expected keys; tolerate unrelated env noise.
verify-apply *args:
  #!/usr/bin/env bash
  set -uo pipefail
  raw=({{args}})
  if [[ ${#raw[@]} -eq 0 ]]; then
    targets=(bin/envfile)
  else
    targets=()
    for arg in "${raw[@]}"; do
      if [[ -x "$arg" ]]; then targets+=("$arg")
      else path=$(bin/lang "$arg" envfile 2>/dev/null) || { echo "unknown impl: $arg"; exit 1; }; targets+=("$path")
      fi
    done
  fi
  ok=1
  tmp_apply_raw_out=$(mktemp)
  tmp_apply_err=$(mktemp)
  tmp_apply_out=$(mktemp)
  trap 'rm -f "$tmp_apply_raw_out" "$tmp_apply_err" "$tmp_apply_out"' EXIT
  for impl in "${targets[@]}"; do
    [[ -x "$impl" ]] || { echo "skip: $impl (not executable)"; continue; }
    while IFS=$'\t' read -r fixture envvars keys; do
      base="${fixture%.env}"
      case "$impl" in
        bin/envfile)
          env -i $envvars bin/envfile format=native action=apply "$fixture" >"$tmp_apply_raw_out" 2>"$tmp_apply_err" || true
          ;;
        *)
          env -i $envvars ENVFILE_FORMAT=native ENVFILE_ACTION=apply \
            "$impl" "$fixture" >"$tmp_apply_raw_out" 2>"$tmp_apply_err" || true
          ;;
      esac
      awk -F= -v keys="$keys" '
        BEGIN {
          n = split(keys, want, /[[:space:]]+/)
          for (i = 1; i <= n; i++) if (want[i] != "") seen[want[i]] = 1
        }
        ($1 in seen) { print }
      ' "$tmp_apply_raw_out" >"$tmp_apply_out"
      fail=0
      if ! diff -q "${base}.err" "$tmp_apply_err" >/dev/null 2>&1; then
        echo "FAIL (stderr): $impl $fixture"
        diff "${base}.err" "$tmp_apply_err"
        fail=1
      fi
      if ! diff -q "${base}.out" "$tmp_apply_out" >/dev/null 2>&1; then
        echo "FAIL (stdout): $impl $fixture"
        diff "${base}.out" "$tmp_apply_out"
        fail=1
      fi
      [[ $fail -eq 0 ]] && echo "ok:   $impl $fixture"
      [[ $fail -eq 0 ]] || ok=0
    done < <(just native::_apply-table)
  done
  [[ $ok -eq 1 ]]

[private]
_normalize-table:
  #!/usr/bin/env bash
  printf '%s\n' \
    "native/normalize/crlf.env	CRLF=ignore	ENVFILE_CRLF=ignore" \
    "native/normalize/crlf.env	CRLF=strip	ENVFILE_CRLF=strip" \
    "native/normalize/crlf_mixed.env	CRLF=ignore	ENVFILE_CRLF=ignore" \
    "native/normalize/crlf_mixed.env	CRLF=strip	ENVFILE_CRLF=strip" \
    "native/normalize/crlf_value_cr.env	CRLF=ignore	ENVFILE_CRLF=ignore" \
    "native/normalize/crlf_value_cr.env	CRLF=strip	ENVFILE_CRLF=strip" \
    "native/normalize/nul.env	NUL=reject	ENVFILE_NUL=reject" \
    "native/normalize/nul.env	NUL=ignore	ENVFILE_NUL=ignore"

[private]
_apply-table:
  #!/usr/bin/env bash
  printf '%s\n' \
    "native/apply/basic.env	A=1 B=2 HOME=/home/user PATH=/usr/local/bin:/usr/bin:/bin	A B BIN CHAIN HOME PATH" \
    "native/apply/edge.env	A=1 HOME=/home/user PATH=/usr/local/bin:/usr/bin:/bin	A BRACED CHAIN HOME LITERAL PATH PRICE SELF" \
    "native/apply/missing.env	A=1 B=2 HOME=/home/user PATH=/usr/local/bin:/usr/bin:/bin	A B BROKEN CHAIN HOME PATH"
