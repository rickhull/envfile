set shell := ["bash", "-cu"]

# Validate the native starter fixtures with the native dispatcher path.
validate:
  #!/usr/bin/env bash
  set -uo pipefail
  while IFS= read -r f; do
    { LC_ALL=C nullscan "$f" >/dev/null && envfile language=awk format=native action=validate "$f"; } || true
  done < <(find native/accepted native/rejected -name "*.env" | sort)

# Dump the native starter fixtures to canonical KEY=VALUE lines.
dump:
  #!/usr/bin/env bash
  set -uo pipefail
  while IFS= read -r f; do
    { LC_ALL=C nullscan "$f" >/dev/null && envfile language=awk format=native action=dump "$f"; } || true
  done < <(find native/accepted native/rejected -name "*.env" | sort)

# Regenerate native normalize golden files from AWK (review diff before committing).
regen-normalize:
  #!/usr/bin/env bash
  set -uo pipefail
  while IFS=$'\t' read -r fixture mode envvars; do
    base="${fixture%.env}"
    env $envvars \
      envfile language=awk format=native action=normalize "$fixture" \
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
    { LC_ALL=C nullscan "$f" >/dev/null && envfile language=awk format=native action=validate "$f"; } \
      > "${base}.err" 2>&1 || true
  done < <(find native/accepted native/rejected -name "*.env" | sort)

# Regenerate native delta golden files against standard.env (review diff before committing).
regen-delta:
  env -i $(grep -v '^#' standard.env | grep -v '^$' | tr '\n' ' ') \
    bin/envfile language=awk format=native action=delta native/delta/basic.env \
    > native/delta/basic.out 2> native/delta/basic.err; true

# Run delta against standard.env and show output.
delta:
  env -i $(grep -v '^#' standard.env | grep -v '^$' | tr '\n' ' ') \
    bin/envfile language=awk format=native action=delta native/delta/basic.env

# Regenerate native apply golden files against a fixed synthetic env.
regen-apply:
  #!/usr/bin/env bash
  set -uo pipefail
  while IFS=$'\t' read -r fixture envvars keys; do
    base="${fixture%.env}"
    tmp_out=$(mktemp)
    tmp_err=$(mktemp)
    env -i $envvars \
      bin/envfile language=awk format=native action=apply "$fixture" \
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
    bin/envfile language=awk format=native action=apply native/apply/basic.env

# Verify normalize passes against native reference sidecars.
verify-normalize *args:
  #!/usr/bin/env bash
  set -uo pipefail
  raw=({{args}})
  if [[ ${#raw[@]} -eq 0 ]]; then
    langs=("awk")
  else
    langs=("${raw[@]}")
  fi
  ok=1
  tmp_norm_out=$(mktemp)
  tmp_norm_err=$(mktemp)
  trap 'rm -f "$tmp_norm_out" "$tmp_norm_err"' EXIT
  for lang in "${langs[@]}"; do
    while IFS=$'\t' read -r fixture mode envvars; do
      base="${fixture%.env}"
      env $envvars \
        envfile "language=$lang" format=native action=normalize "$fixture" \
        >"$tmp_norm_out" 2>"$tmp_norm_err" || true
      fail=0
      if ! diff -q "${base}.${mode}.err" "$tmp_norm_err" >/dev/null 2>&1; then
        echo "FAIL (stderr): $lang $fixture [$mode]"
        diff "${base}.${mode}.err" "$tmp_norm_err"
        fail=1
      fi
      ref_out="${base}.${mode}.out"
      if [[ -f "$ref_out" ]]; then
        if ! diff -q "$ref_out" "$tmp_norm_out" >/dev/null 2>&1; then
          echo "FAIL (stdout): $lang $fixture [$mode]"
          diff "$ref_out" "$tmp_norm_out"
          fail=1
        fi
      elif [[ -s "$tmp_norm_out" ]]; then
        echo "FAIL (stdout): $lang $fixture [$mode] — unexpected output"
        cat "$tmp_norm_out"
        fail=1
      fi
      [[ $fail -eq 0 ]] && echo "ok:   $lang $fixture [$mode]"
      [[ $fail -eq 0 ]] || ok=0
    done < <(just native::_normalize-table)
  done
  [[ $ok -eq 1 ]]

# Verify implementations against the native starter references.
# Runs validate, normalize, delta, and apply checks.
verify *args:
  just native::verify-validate {{args}}
  just native::verify-normalize {{args}}
  just native::verify-delta {{args}}
  just native::verify-apply {{args}}

# Verify validate fixtures against native reference sidecars.
[private]
verify-validate *args:
  #!/usr/bin/env bash
  set -uo pipefail
  raw=({{args}})
  if [[ ${#raw[@]} -eq 0 ]]; then
    langs=($(lang list))
  else
    langs=("${raw[@]}")
  fi
  ok=1
  for lang in "${langs[@]}"; do
    just native::do_verify "$lang" || ok=0
  done
  [[ $ok -eq 1 ]]

# Compare a single implementation against all native fixtures with sidecars.
# delta/ and lame.env are handled by dedicated recipes and excluded here.
[private]
do_verify lang:
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
    if ! LC_ALL=C nullscan "$envfile" >/dev/null 2>"$tmp_got_err"; then
      got_out=""
    else
      got_out=$(envfile "language={{lang}}" format=native "$envfile" 2>"$tmp_got_err" || true)
    fi
    got_err=$(cat "$tmp_got_err")
    fail=0
    if [[ "$got_err" != "$ref_err" ]]; then
      echo "FAIL (stderr): {{lang}} $envfile"
      diff <(echo "$ref_err") <(echo "$got_err")
      fail=1
    fi
    if [[ "$got_out" != "$ref_out" ]]; then
      echo "FAIL (stdout): {{lang}} $envfile"
      diff <(echo "$ref_out") <(echo "$got_out")
      fail=1
    fi
    [[ $fail -eq 0 ]] && echo "ok:   {{lang}} $envfile"
    [[ $fail -eq 0 ]] || ok=0
  done < <(find native/accepted native/rejected -name "*.env" | sort)
  [[ $ok -eq 1 ]]

# Verify apply fixtures against the native reference output.
# Verify delta fixtures against standard.env baseline.
verify-delta *args:
  #!/usr/bin/env bash
  set -uo pipefail
  raw=({{args}})
  if [[ ${#raw[@]} -eq 0 ]]; then
    langs=("awk")
  else
    langs=("${raw[@]}")
  fi
  ok=1
  tmp_delta_out=$(mktemp)
  tmp_delta_err=$(mktemp)
  trap 'rm -f "$tmp_delta_out" "$tmp_delta_err"' EXIT
  for lang in "${langs[@]}"; do
    while IFS=$'\t' read -r fixture envvars; do
      base="${fixture%.env}"
      env -i ENVFILE_RUNTIME_PATH="$PATH" $envvars \
        bin/envfile "language=$lang" format=native action=delta "$fixture" \
        >"$tmp_delta_out" 2>"$tmp_delta_err" || true
      fail=0
      if ! diff -q "${base}.err" "$tmp_delta_err" >/dev/null 2>&1; then
        echo "FAIL (stderr): $lang $fixture"
        diff "${base}.err" "$tmp_delta_err"
        fail=1
      fi
      if ! diff -q "${base}.out" "$tmp_delta_out" >/dev/null 2>&1; then
        echo "FAIL (stdout): $lang $fixture"
        diff "${base}.out" "$tmp_delta_out"
        fail=1
      fi
      [[ $fail -eq 0 ]] && echo "ok:   $lang $fixture"
      [[ $fail -eq 0 ]] || ok=0
    done < <(just native::_delta-table)
  done
  [[ $ok -eq 1 ]]

[private]
_delta-table:
  #!/usr/bin/env bash
  printf '%s\n' \
    "native/delta/basic.env	HOME=/home/user PATH=/usr/local/bin:/usr/bin:/bin TERM=xterm-256color EDITOR=vim PAGER=less"

# Compare only the fixture's explicit expected keys; tolerate unrelated env noise.
verify-apply *args:
  #!/usr/bin/env bash
  set -uo pipefail
  raw=({{args}})
  if [[ ${#raw[@]} -eq 0 ]]; then
    langs=("awk")
  else
    langs=("${raw[@]}")
  fi
  ok=1
  tmp_apply_raw_out=$(mktemp)
  tmp_apply_err=$(mktemp)
  tmp_apply_out=$(mktemp)
  trap 'rm -f "$tmp_apply_raw_out" "$tmp_apply_err" "$tmp_apply_out"' EXIT
  for lang in "${langs[@]}"; do
    while IFS=$'\t' read -r fixture envvars keys; do
      base="${fixture%.env}"
      env -i ENVFILE_RUNTIME_PATH="$PATH" $envvars \
        bin/envfile "language=$lang" format=native action=apply "$fixture" \
        >"$tmp_apply_raw_out" 2>"$tmp_apply_err" || true
      awk -F= -v keys="$keys" '
        BEGIN {
          n = split(keys, want, /[[:space:]]+/)
          for (i = 1; i <= n; i++) if (want[i] != "") seen[want[i]] = 1
        }
        ($1 in seen) { print }
      ' "$tmp_apply_raw_out" >"$tmp_apply_out"
      fail=0
      if ! diff -q "${base}.err" "$tmp_apply_err" >/dev/null 2>&1; then
        echo "FAIL (stderr): $lang $fixture"
        diff "${base}.err" "$tmp_apply_err"
        fail=1
      fi
      if ! diff -q "${base}.out" "$tmp_apply_out" >/dev/null 2>&1; then
        echo "FAIL (stdout): $lang $fixture"
        diff "${base}.out" "$tmp_apply_out"
        fail=1
      fi
      [[ $fail -eq 0 ]] && echo "ok:   $lang $fixture"
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
