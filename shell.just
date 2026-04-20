set shell := ["bash", "-cu"]

# Regenerate all shell golden files (review diff before committing).
regen: regen-normalize
  envfile language=awk format=shell action=validate shell/accepted/accepted.env  > shell/accepted/accepted.err  2>&1
  envfile language=awk format=shell action=validate shell/accepted/lowercase.env > shell/accepted/lowercase.err 2>&1
  envfile language=awk format=shell action=validate shell/rejected/rejected.env  > shell/rejected/rejected.err  2>&1 || true
  envfile language=awk format=shell action=validate shell/mixed/combined.env     > shell/mixed/combined.err     2>&1 || true

# Regenerate shell normalize golden files from AWK (review diff before committing).
regen-normalize:
  #!/usr/bin/env bash
  set -uo pipefail
  while IFS=$'\t' read -r fixture mode envvars; do
    base="${fixture%.env}"
    env $envvars \
      envfile language=awk format=shell action=normalize "$fixture" \
      > "${base}.${mode}.out" 2>"${base}.${mode}.err" || true
    [[ -s "${base}.${mode}.out" ]] || rm -f "${base}.${mode}.out"
    echo "wrote: ${base}.${mode}.{err,out}"
  done < <(just shell::_normalize-table)

# Regenerate shell dump golden files from AWK (review diff before committing).
regen-dump:
  #!/usr/bin/env bash
  set -uo pipefail
  while IFS=$'\t' read -r fixture envvars; do
    base="${fixture%.env}"
    env $envvars \
      envfile language=awk format=shell action=dump "$fixture" \
      > "${base}.out" 2>"${base}.err" || true
    echo "wrote: ${base}.{err,out}"
  done < <(just shell::_dump-table)

# Validate the shell starter fixtures.
validate:
  envfile language=awk format=shell action=validate shell/accepted/accepted.env
  envfile language=awk format=shell action=validate shell/accepted/lowercase.env
  envfile language=awk format=shell action=validate shell/rejected/rejected.env || true
  envfile language=awk format=shell action=validate shell/mixed/combined.env || true

# Dump the shell starter fixtures to canonical KEY=VALUE lines.
dump:
  envfile language=awk format=shell action=dump shell/accepted/accepted.env
  envfile language=awk format=shell action=dump shell/accepted/lowercase.env
  envfile language=awk format=shell action=dump shell/mixed/combined.env || true

# Verify normalize passes against shell reference sidecars.
verify-normalize *args:
  #!/usr/bin/env bash
  set -uo pipefail
  raw=({{args}})
  if [[ ${#raw[@]} -eq 0 ]]; then
    langs=($(lang list))
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
        envfile "language=$lang" format=shell action=normalize "$fixture" \
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
    done < <(just shell::_normalize-table)
  done
  [[ $ok -eq 1 ]]

# Verify dump passes against shell reference sidecars.
verify-dump *args:
  #!/usr/bin/env bash
  set -uo pipefail
  raw=({{args}})
  if [[ ${#raw[@]} -eq 0 ]]; then
    langs=("awk")
  else
    langs=("${raw[@]}")
  fi
  ok=1
  tmp_dump_out=$(mktemp)
  tmp_dump_err=$(mktemp)
  trap 'rm -f "$tmp_dump_out" "$tmp_dump_err"' EXIT
  for lang in "${langs[@]}"; do
    while IFS=$'\t' read -r fixture envvars; do
      base="${fixture%.env}"
      env $envvars \
        envfile "language=$lang" format=shell action=dump "$fixture" \
        >"$tmp_dump_out" 2>"$tmp_dump_err" || true
      fail=0
      if ! diff -q "${base}.err" "$tmp_dump_err" >/dev/null 2>&1; then
        echo "FAIL (stderr): $lang $fixture"
        diff "${base}.err" "$tmp_dump_err"
        fail=1
      fi
      if ! diff -q "${base}.out" "$tmp_dump_out" >/dev/null 2>&1; then
        echo "FAIL (stdout): $lang $fixture"
        diff "${base}.out" "$tmp_dump_out"
        fail=1
      fi
      [[ $fail -eq 0 ]] && echo "ok:   $lang $fixture"
      [[ $fail -eq 0 ]] || ok=0
    done < <(just shell::_dump-table)
  done
  [[ $ok -eq 1 ]]

# Verify implementations against shell reference output.
# Runs validate, normalize, and dump checks.
verify *args:
  just shell::verify-validate {{args}}
  just shell::verify-normalize {{args}}
  just shell::verify-dump {{args}}

# Verify validate fixtures against shell reference sidecars.
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
    just shell::do_verify "$lang" || ok=0
  done
  [[ $ok -eq 1 ]]

# Compare a single implementation against all shell validate fixtures with sidecars.
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
    got_out=$(envfile "language={{lang}}" "$envfile" 2>"$tmp_got_err" || true)
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
  done < <(find shell -name "*.env" ! -path "shell/dump/*" | sort)
  [[ $ok -eq 1 ]]

# Cross-check: bash must agree on values in accepted and mixed fixtures.
check-bash-accepted:
  #!/usr/bin/env python3
  import subprocess, sys

  def parse_envfile(path):
    result = {}
    with open(path) as f:
      for line in f:
        line = line.rstrip("\n")
        if not line or line.startswith("#") or "=" not in line:
          continue
        key, _, value = line.partition("=")
        if key != key.strip():
          continue
        if value.startswith(("'", '"')):
          value = value[1:-1]
        result[key] = value
    return result

  def bash_env(path):
    result = subprocess.run(
      ["bash", "-c", f"set -a; source {path}; set +a; env"],
      capture_output=True, text=True
    )
    env = {}
    for line in result.stdout.splitlines():
      k, _, v = line.partition("=")
      env[k] = v
    return env, result.returncode, result.stderr

  def check_values(label, path, keys):
    expected = parse_envfile(path)
    env, _, _ = bash_env(path)
    ok = True
    for key in sorted(keys):
      exp = expected[key]
      got = env.get(key, "<missing>")
      if got != exp:
        print(f"FAIL [{label}]: {key}")
        print(f"  expected: {exp!r}")
        print(f"  bash got: {got!r}")
        ok = False
      else:
        print(f"ok   [{label}]: {key}={exp!r}")
    return ok

  overall = True

  overall &= check_values("accepted",  "shell/accepted/accepted.env",  parse_envfile("shell/accepted/accepted.env").keys())
  overall &= check_values("lowercase", "shell/accepted/lowercase.env", parse_envfile("shell/accepted/lowercase.env").keys())

  # For mixed: exclude lines the dispatcher reports as errors
  result = subprocess.run(["envfile", "language=awk", "shell/mixed/combined.env"], capture_output=True, text=True)
  error_lines = set()
  for line in result.stderr.splitlines():
    if not line.startswith("LINE_ERROR"):
      continue
    _, _, loc = line.partition(": ")
    _, _, lineno = loc.rpartition(":")
    if lineno.isdigit():
      error_lines.add(int(lineno))

  valid_combined = {}
  with open("shell/mixed/combined.env") as f:
    for lineno, line in enumerate(f, 1):
      line = line.rstrip("\n")
      if not line or line.startswith("#") or "=" not in line:
        continue
      key, _, value = line.partition("=")
      if lineno not in error_lines and key == key.strip():
        if value.startswith(("'", '"')):
          value = value[1:-1]
        valid_combined[key] = value
  overall &= check_values("combined", "shell/mixed/combined.env", valid_combined.keys())

  sys.exit(0 if overall else 1)

# Cross-check: bash must emit errors when sourcing rejected fixtures.
check-bash-rejected:
  #!/usr/bin/env python3
  import subprocess, sys

  def bash_env(path):
    result = subprocess.run(
      ["bash", "-c", f"set -a; source {path}; set +a; env"],
      capture_output=True, text=True
    )
    return result.returncode, result.stderr

  overall = True

  rc, stderr = bash_env("shell/rejected/rejected.env")
  if stderr.strip():
    print("ok   [rejected]: bash emitted errors (as expected)")
  else:
    print("FAIL [rejected]: bash sourced rejected.env with no errors")
    overall = False

  sys.exit(0 if overall else 1)

# Cross-check: run both bash checks.
check-bash: check-bash-accepted check-bash-rejected

[private]
_normalize-table:
  #!/usr/bin/env bash
  printf '%s\n' \
    "shell/normalize/bom.env	BOM=reject	ENVFILE_BOM=reject" \
    "shell/normalize/bom.env	BOM=literal	ENVFILE_BOM=literal" \
    "shell/normalize/bom.env	BOM=strip	ENVFILE_BOM=strip" \
    "shell/normalize/crlf.env	CRLF=ignore	ENVFILE_CRLF=ignore" \
    "shell/normalize/crlf.env	CRLF=strip	ENVFILE_CRLF=strip" \
    "shell/normalize/crlf_mixed.env	CRLF=ignore	ENVFILE_CRLF=ignore" \
    "shell/normalize/crlf_mixed.env	CRLF=strip	ENVFILE_CRLF=strip" \
    "shell/normalize/nul.env	NUL=reject	ENVFILE_NUL=reject" \
    "shell/normalize/nul.env	NUL=ignore	ENVFILE_NUL=ignore" \
    "shell/normalize/continuation.env	CONT=ignore	ENVFILE_BACKSLASH_CONTINUATION=ignore" \
    "shell/normalize/continuation.env	CONT=accept	ENVFILE_BACKSLASH_CONTINUATION=accept"

[private]
_dump-table:
  #!/usr/bin/env bash
  printf '%s\n' \
    "shell/dump/edge.env"
