set shell := ["bash", "-cu"]

# Regenerate strict reference outputs from the dispatcher.
generate-reference:
  bin/envfile strict/accepted.env > strict/accepted.txt 2>&1
  bin/envfile strict/rejected.env > strict/rejected.txt 2>&1 || true
  bin/envfile strict/lowercase.env > strict/lowercase.txt 2>&1
  bin/envfile strict/windows.env > strict/windows.txt 2>&1 || true
  bin/envfile strict/combined.env > strict/combined.txt 2>&1 || true

# Validate the strict starter fixtures with the strict dispatcher path.
validate:
  bin/envfile format=strict action=validate strict/accepted.env
  bin/envfile format=strict action=validate strict/rejected.env || true
  bin/envfile format=strict action=validate strict/lowercase.env
  bin/envfile format=strict action=validate strict/windows.env || true
  bin/envfile format=strict action=validate strict/combined.env || true

# Normalize the strict starter fixtures to canonical KEY=VALUE lines.
normalize:
  bin/envfile format=strict action=normalize strict/accepted.env
  bin/envfile format=strict action=normalize strict/lowercase.env
  bin/envfile format=strict action=normalize strict/combined.env || true

# Verify implementations against strict reference output.
verify *args:
  #!/usr/bin/env bash
  set -uo pipefail
  targets=({{args}})
  [[ ${#targets[@]} -eq 0 ]] && targets=(bin/envfile bin/envfile.*)
  ok=1
  for impl in "${targets[@]}"; do
    [[ -x "$impl" ]] || { echo "skip: $impl (not executable)"; continue; }
    just strict::do_verify "$impl" || ok=0
  done
  [[ $ok -eq 1 ]]

# Compare a single implementation against all strict fixtures.
[private]
do_verify impl:
  #!/usr/bin/env bash
  set -uo pipefail
  ok=1
  for f in accepted rejected lowercase windows combined; do
    got=$({{impl}} strict/${f}.env 2>&1 || true)
    ref=$(cat strict/${f}.txt)
    if [[ "$got" != "$ref" ]]; then
      echo "FAIL: {{impl}} strict/${f}.env"
      diff <(echo "$ref") <(echo "$got")
      ok=0
    else
      echo "ok:   {{impl}} strict/${f}.env"
    fi
  done
  [[ $ok -eq 1 ]]

# Verify bash agrees with the strict fixtures on accepted key/value pairs.
verify-bash:
  #!/usr/bin/env python3
  import subprocess, sys

  def parse_envfile(path):
    """Return {key: value} for valid-looking assignments; skip blanks and comments."""
    result = {}
    with open(path) as f:
      for line in f:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
          continue
        if "=" not in line:
          continue
        key, _, value = line.partition("=")
        if key != key.strip():
          continue
        if value.startswith(("'", '"')):
          value = value[1:-1]
        result[key] = value
    return result

  def bash_env(path):
    """Source path in bash and return the resulting env as a dict."""
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
    """For each key, verify bash agrees on the value. Returns True if all ok."""
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

  accepted = parse_envfile("strict/accepted.env")
  overall &= check_values("accepted", "strict/accepted.env", accepted.keys())

  lowercase = parse_envfile("strict/lowercase.env")
  overall &= check_values("lowercase", "strict/lowercase.env", lowercase.keys())

  lint = subprocess.run(["bin/envfile", "strict/combined.env"], capture_output=True, text=True)
  error_lines = set()
  for line in lint.stderr.splitlines():
    if not line.startswith("ERROR: ("):
      continue
    loc = line[len("ERROR: ("):line.index(")")]
    _, _, lineno = loc.rpartition(":")
    if lineno.isdigit():
      error_lines.add(int(lineno))

  valid_combined = {}
  with open("strict/combined.env") as f:
    for lineno, line in enumerate(f, 1):
      line = line.rstrip("\n")
      if not line or line.startswith("#") or "=" not in line:
        continue
      key, _, value = line.partition("=")
      if lineno not in error_lines and key == key.strip():
        if value.startswith(("'", '"')):
          value = value[1:-1]
        valid_combined[key] = value
  overall &= check_values("combined", "strict/combined.env", valid_combined.keys())

  _, rc, stderr = bash_env("strict/rejected.env")
  if stderr.strip():
    print("ok   [rejected]: bash emitted errors (as expected)")
  else:
    print("FAIL [rejected]: bash sourced rejected.env with no errors")
    overall = False

  sys.exit(0 if overall else 1)

[private]
