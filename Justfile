set shell := ["bash", "-cu"]

# Adjust process scheduling for more accurate benchmarks
mod bench

# Build native binaries: go, zig, all, clean (etc)
mod build

# Corpus mining: find, collect
mod corpus

default:
  @just --list
  just --list bench
  just --list build
  just --list corpus  

# Sets available linters to executable; ensures we have bin/bench
activate: ensure-bench
  #!/usr/bin/env python3
  import os, subprocess, tomllib

  with open("implementations.toml", "rb") as f:
    impls = tomllib.load(f)

  for path, meta in impls.items():
    if meta.get("runtime") != "interpreted":
      continue
    if not os.path.isfile(path):
      continue
    check = meta["check"]
    available = subprocess.run(check, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if available:
      os.chmod(path, 0o755)
      print(f"activated: {path}")
    else:
      os.chmod(path, 0o644)
      print(f"skipped:   {path} ({meta['tool']} not available)")

  # Symlink bin/lint to best available reference impl
  priority = ["bin/lint.awk", "bin/lint.pl", "bin/lint.bash", "bin/lint.sh"]
  link = "bin/lint"
  if os.path.exists(link) or os.path.islink(link):
    os.unlink(link)
  for candidate in priority:
    if os.access(candidate, os.X_OK):
      target = os.path.basename(candidate)
      os.symlink(target, link)
      print(f"symlinked: {link} -> {target}")
      break

# Restores pre-activation state (executable bit, symlinks)
deactivate:
  #!/usr/bin/env python3
  import os, tomllib

  with open("implementations.toml", "rb") as f:
    impls = tomllib.load(f)

  for path, meta in impls.items():
    if meta.get("runtime") != "interpreted":
      continue
    if not os.path.isfile(path):
      continue
    os.chmod(path, 0o644)
    print(f"deactivated: {path}")

  link = "bin/lint"
  if os.path.exists(link) or os.path.islink(link):
    os.unlink(link)
    print(f"removed: {link}")

  bench = "bin/bench"
  if os.path.islink(bench) and os.readlink(bench) == "pybench":
    os.unlink(bench)
    print(f"removed: {bench} -> pybench")

# Generate reference outputs from the activated reference implementation
generate-reference: activated
  bin/lint spec/accepted.env > spec/accepted.txt 2>&1
  bin/lint spec/rejected.env > spec/rejected.txt 2>&1 || true
  bin/lint spec/warning.env > spec/warning.txt 2>&1
  bin/lint spec/windows.env > spec/windows.txt 2>&1 || true
  bin/lint spec/combined.env > spec/combined.txt 2>&1 || true

# Verify impls match reference output (default: all)
verify *args:
  #!/usr/bin/env bash
  set -uo pipefail
  targets=({{args}})
  [[ ${#targets[@]} -eq 0 ]] && targets=(bin/lint.*)
  ok=1
  for impl in "${targets[@]}"; do
    [[ -x "$impl" ]] || { echo "skip: $impl (not executable)"; continue; }
    just do_verify "$impl" || ok=0
  done
  [[ $ok -eq 1 ]]

[private]
do_verify impl:
  #!/usr/bin/env bash
  set -uo pipefail
  ok=1
  for f in accepted rejected warning windows combined; do
    got=$({{impl}} spec/${f}.env 2>&1 || true)
    ref=$(cat spec/${f}.txt)
    if [[ "$got" != "$ref" ]]; then
      echo "FAIL: {{impl}} spec/${f}.env"
      diff <(echo "$ref") <(echo "$got")
      ok=0
    else
      echo "ok:   {{impl}} spec/${f}.env"
    fi
  done
  [[ $ok -eq 1 ]]

# Verify bash agrees on key=value pairs for spec files
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

  # accepted.env — all keys; bash must agree on every value
  accepted = parse_envfile("spec/accepted.env")
  overall &= check_values("accepted", "spec/accepted.env", accepted.keys())

  # warning.env — all keys; warnings don't affect value correctness
  warning = parse_envfile("spec/warning.env")
  overall &= check_values("warning ", "spec/warning.env", warning.keys())

  # combined.env — only keys on lines with no errors (determined by bin/lint output)
  lint = subprocess.run(["bin/lint", "spec/combined.env"], capture_output=True, text=True)
  error_lines = set()
  for line in lint.stderr.splitlines():
    if not line.startswith("ERROR: ("):
      continue
    loc = line[len("ERROR: ("):line.index(")")]
    _, _, lineno = loc.rpartition(":")
    if lineno.isdigit():
      error_lines.add(int(lineno))
  combined_all = parse_envfile("spec/combined.env")
  # Re-parse with line numbers to exclude error lines
  valid_combined = {}
  with open("spec/combined.env") as f:
    for lineno, line in enumerate(f, 1):
      line = line.rstrip("\n")
      if not line or line.startswith("#") or "=" not in line:
        continue
      key, _, value = line.partition("=")
      if lineno not in error_lines and key == key.strip():
        if value.startswith(("'", '"')):
          value = value[1:-1]
        valid_combined[key] = value
  overall &= check_values("combined", "spec/combined.env", valid_combined.keys())

  # rejected.env — bash must emit errors (stderr non-empty)
  _, rc, stderr = bash_env("spec/rejected.env")
  if stderr.strip():
    print(f"ok   [rejected]: bash emitted errors (as expected)")
  else:
    print(f"FAIL [rejected]: bash sourced rejected.env with no errors")
    overall = False

  sys.exit(0 if overall else 1)

[private]
@activated:
  @[[ -e bin/lint ]] || just activate

[private]
ensure-bench:
  #!/usr/bin/env perl
  my $err = `just build::bench 2>&1`;
  if ($? == 0) {
      print "bench: built from C\n";
  } else {
      warn "bench: C build failed:\n$err";
      warn "bench: falling back to pybench\n";
      symlink("pybench", "bin/bench") or die "symlink failed: $!\n";
      print "bench: bin/bench -> pybench\n";
  }
