set shell := ["bash", "-cu"]

corpus_dir    := "corpus/files"
explored_file := "corpus/explored.txt"
filtered_file := "corpus/filtered.txt"
max_filesize  := "5K"

blacklist := '(secret|\.secret\.)|(\.(js|ts|jsx|tsx|mjs|cjs|json|jsonl|jsonc|yaml|yml|toml|md|svg|png|ico|jpg|gif|wav|beam|roc|zig|rs|rb|ex|exs|erl|hrl|db|db-wal|db-journal|def|result-ast|elixir|elixir_scm|app|app_cache|appup|lock|log|heex|eex|snap|css|html|xml|po|pot|sql|tar|gz|xz|zst|lzma|bin|pem|crt|der|sig|so|o|a|dylib|dll|exe|go|py|pl|pm|mo|cmake|pc|mod|ri|dyn_hi|elc|tablet|md5sums|list|triggers|shlibs|h|c|cpp|hpp|s|S|pak|xpm|rbs|scm|asn1|pub|pbm|hex|symbols|[0-9])$)'

exclude_globs := "-g !.git/ -g !node_modules/ -g !__pycache__/ -g !vendor/ -g !target/ -g !/proc/ -g !/sys/ -g !/dev/ -g !/run/ -g !/tmp/"

shellconf_patterns := '(?i)(.*conf.*\.sh)$'

rg_files := "rg --files --no-messages --no-ignore --hidden --one-file-system"

# Collect real-world env files from the local filesystem.
#
# Generation composes three stages:
#   1. explore  — find candidate files (by directory walk, systemd refs, or filename patterns)
#   2. filter   — validate each candidate, keep those passing size-tiered acceptance thresholds
#   3. collect  — sanitize sensitive lines, copy to corpus/files/ (chroot layout), score source dirs
#
# Explore recipes accumulate into `corpus/explored.txt`; `generate` runs the
# full pipeline once after all exploration completes.

# Run the full corpus pipeline once.
generate: clean explore_all filter collect

# Run every explore stage without building the final corpus tree.
explore_all: explore_home explore_root explore_systemd explore_shellconf

# Alias for exploring `$HOME`.
home: explore_home

# Alias for exploring the filesystem root.
root: explore_root

# Alias for exploring `EnvironmentFile=` references from systemd units.
systemd: explore_systemd

# Alias for exploring shell config filenames.
shellconf: explore_shellconf

# --- Explore -----------------------------------------------------------------

# Reset the staged explore/filter outputs.
clean-state:
  rm -f "{{explored_file}}" "{{filtered_file}}"

# Explore files under `$HOME`.
explore_home: (explore "$HOME")

# Explore files across the filesystem root.
explore_root: (explore "/")

# Explore candidate env-like files under a directory.
explore dir="/" glob="":
  #!/usr/bin/env bash
  dir="{{dir}}"
  glob="{{glob}}"
  tmp=$(mktemp)
  merged=$(mktemp)

  {{rg_files}} \
    --max-filesize "{{max_filesize}}" \
    ${glob:+-g "$glob"} \
    {{exclude_globs}} \
    "$dir" \
  | rg -vi "{{blacklist}}" \
  | rg -vF "$(pwd)/" \
  | sort \
  | xargs -d '\n' rg --no-messages -l '=' \
  > "$tmp"

  cat "{{explored_file}}" "$tmp" 2>/dev/null | sort -u > "$merged"
  mv "$merged" "{{explored_file}}"
  rm -f "$tmp"

  count=$(wc -l < {{explored_file}})
  msg="Accumulated ${count} files after scanning ${dir}"
  printf 'explore:\t%s\n' "$msg"
  printf '\t\tWrote {{explored_file}}\n'

# Explore shell config files matching `*conf*.sh`.
explore_shellconf:
  #!/usr/bin/env bash
  tmp=$(mktemp)
  merged=$(mktemp)

  {{rg_files}} \
    --max-filesize "{{max_filesize}}" \
    --glob-case-insensitive \
    -g "!*.service" \
    {{exclude_globs}} \
    / \
  | rg -i "{{shellconf_patterns}}" \
  | rg -vF "$(pwd)/" \
  | xargs -d '\n' rg --no-messages -l '=' \
  > "$tmp"

  cat "{{explored_file}}" "$tmp" 2>/dev/null | sort -u > "$merged"
  mv "$merged" "{{explored_file}}"
  rm -f "$tmp"

  count=$(wc -l < {{explored_file}})
  msg="Accumulated ${count} files after shellconf scan"
  printf 'explore_shellconf:\t%s\n' "$msg"
  printf '\t\tWrote {{explored_file}}\n'

# Explore `EnvironmentFile=` references from systemd units.
explore_systemd:
  #!/usr/bin/env python3
  import os, re, subprocess

  explored_file = "{{explored_file}}"
  envfile_re    = re.compile(r"^EnvironmentFile=(.+)", re.MULTILINE)
  seen          = set()

  # Systemd specifier expansion (best-effort, common cases only)
  import getpass, socket
  machine_id = open("/etc/machine-id").read().strip() if os.path.exists("/etc/machine-id") else ""
  specifiers = {
    "%h": os.path.expanduser("~"),
    "%u": getpass.getuser(),
    "%H": socket.gethostname(),
    "%m": machine_id,
    "%%": "%",
  }

  def expand_specifiers(s):
    for k, v in specifiers.items():
      s = s.replace(k, v)
    return s

  rg_files = "{{rg_files}}".split()
  exclude = "{{exclude_globs}}".split()
  r = subprocess.run(
    rg_files + ["--max-filesize", "{{max_filesize}}", "-g", "*.service"] + exclude + ["/"],
    capture_output=True, text=True
  )
  units = [l for l in r.stdout.splitlines() if l]

  refs = []
  for unit in units:
    try:
      content = open(unit, errors="replace").read()
    except OSError:
      continue
    for ref in envfile_re.findall(content):
      ref = ref.strip()
      if ref.startswith("-"):
        ref = ref[1:]
      ref = expand_specifiers(ref)
      if not os.path.isabs(ref):
        ref = os.path.normpath(os.path.join(os.path.dirname(unit), ref))
      if ref in seen or not os.path.isfile(ref):
        continue
      seen.add(ref)
      refs.append(ref)

  prior = []
  if os.path.exists(explored_file):
    with open(explored_file) as f:
      prior = [line.rstrip("\n") for line in f if line.strip()]

  with open(explored_file, "w") as f:
    for ref in sorted(set(prior) | set(refs)):
      f.write(ref + "\n")

  total = sum(1 for _ in open(explored_file))
  msg = f"Found {len(units)} unit files; accumulated {total} files after systemd refs"
  print(f"explore_systemd:\t{msg}")
  print(f"\t\tWrote {explored_file}")

# --- Filter ------------------------------------------------------------------

# Filter explored paths through the native format validator.
filter:
  #!/usr/bin/env python3
  import os, re, subprocess, sys

  explored_file = "{{explored_file}}"
  filtered_file = "{{filtered_file}}"

  def find_validator():
    result = subprocess.run(["bin/lang", "list", "built"], capture_output=True, text=True)
    for lang in result.stdout.splitlines():
      r = subprocess.run(["bin/lang", lang, "envfile"], capture_output=True, text=True)
      if r.returncode == 0:
        path = r.stdout.strip()
        if os.access(path, os.X_OK):
          return path
    return None

  validator = find_validator()
  if validator is None:
    print("filter: \tno native validator found — run `make c` or similar", file=sys.stderr)
    raise SystemExit(1)

  summary_re  = re.compile(r"(\d+) checked, (\d+) errors, (\d+) warnings")
  overlay_re  = re.compile(r"overlay/[0-9a-f]{64}/diff(/.*)")
  seen_logical = set()
  accepted = skipped = 0

  # Size-tiered acceptance thresholds (applied independently to error and warning rates)
  #   tiny   < 100B : 10% max
  #   small  < 500B : 25% max
  #   medium < 1KB  : 50% max
  #   large  >= 1KB : 75% max
  err_thresholds  = [(100, 0.10), (500, 0.25), (1000, 0.50), (float("inf"), 0.75)]
  warn_thresholds = [(100, 0.10), (500, 0.25), (1000, 0.50), (float("inf"), 0.75)]

  def max_rate(thresholds, size):
    for limit, rate in thresholds:
      if size < limit:
        return rate

  with open(explored_file) as inp, open(filtered_file, "w") as out:
    for path in inp:
      path = path.rstrip("\n")
      if overlay_re.search(path):
        skipped += 1
        continue
      if path in seen_logical:
        skipped += 1
        continue
      r = subprocess.run([validator, path], capture_output=True)
      output = r.stderr.decode("utf-8", errors="replace") + r.stdout.decode("utf-8", errors="replace")
      m = summary_re.search(output)
      if not m:
        continue
      checked, errors, warnings = int(m.group(1)), int(m.group(2)), int(m.group(3))
      if checked == 0:
        continue
      size = os.path.getsize(path)
      if errors   / checked > max_rate(err_thresholds,  size):
        skipped += 1
        continue
      if warnings / checked > max_rate(warn_thresholds, size):
        skipped += 1
        continue
      seen_logical.add(path)
      out.write(path + "\n")
      accepted += 1

  msg = f"Accepted {accepted} files, {validator} skipped {skipped}"
  print(f"filter: \t{msg}")
  print(f"\t\tWrote {filtered_file}")

# --- Collect ------------------------------------------------------------------

# Copy accepted files into the sanitized corpus tree.
collect: &&chown
  #!/usr/bin/env python3
  import os, re, random

  filtered_file = "{{filtered_file}}"
  dest          = "{{corpus_dir}}"

  BAD_WORDS = ["secret", "private", "token", "key", "ssh", "auth", "passw", "passwd", "cred", "cert", "signing"]
  SUB_WORDS = ["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO", "FOXTROT", "GOLF", "HOTEL", "INDIA", "JULIET", "KILO", "LIMA", "MIKE", "NOVEMBER", "OSCAR", "PAPA", "QUEBEC", "ROMEO", "SIERRA", "TANGO", "UNIFORM", "VICTOR", "WHISKEY", "XRAY", "YANKEE", "ZULU"]
  bad_pat   = re.compile("|".join(BAD_WORDS), re.IGNORECASE)

  def sanitize_line(line):
    if "=" not in line or line.startswith("#"):
      return line
    line  = line.rstrip("\n")
    key, sep, value = line.partition("=")
    if not bad_pat.search(key) and not bad_pat.search(value):
      return line + "\n"
    half  = value[:max(1, len(value) // 2)]
    value = half + half[::-1]
    key   = bad_pat.sub(lambda m: random.choice(SUB_WORDS), key)
    value = bad_pat.sub(lambda m: random.choice(SUB_WORDS), value)
    return key + sep + value + "\n"

  os.makedirs(dest, exist_ok=True)
  seen_sources = set()
  for root, _, files in os.walk(dest):
    for fn in files:
      seen_sources.add(os.path.join(root, fn))
  accepted = 0

  import re as _re
  home_user_re = _re.compile(r'^/home/[^/]+/')
  def normalize_home(p):
    return home_user_re.sub('/home/user/', p)

  with open(filtered_file) as f:
    for path in f:
      path = path.rstrip("\n")
      dst = os.path.join(dest, normalize_home(path).lstrip("/"))
      if dst in seen_sources:
        continue
      try:
        lines = open(path, errors="replace").readlines()
      except OSError:
        continue
      sanitized = [sanitize_line(l) for l in lines]
      blob = "".join(sanitized)
      os.makedirs(os.path.dirname(dst), exist_ok=True)
      with open(dst, "w") as out:
        out.write(blob)
      seen_sources.add(dst)
      accepted += 1

  print(f"collect:\tSanitized {accepted} files to {dest}/")

# Score corpus directories by file count.
score:
  #!/usr/bin/env python3
  import os
  from collections import defaultdict
  dest   = "{{corpus_dir}}"
  scores = defaultdict(int)
  for dirpath, _, filenames in os.walk(dest):
    if not filenames:
      continue
    rel = os.path.normpath(os.path.relpath(dirpath, dest)) if dirpath != dest else "."
    scores[rel] += len(filenames)
  for d, n in sorted(scores.items(), key=lambda x: (-x[1], x[0])):
    print(f"{n:>5}  {d}")

# --- Housekeeping -------------------------------------------------------------

# Match corpus file ownership to the repository owner.
chown:
  @chown -R "$(stat -c '%U:%G' '{{justfile_directory()}}')" {{corpus_dir}}/

# Remove collected corpus files.
clean-files:
  find {{corpus_dir}} -mindepth 1 -delete

# Remove all corpus state, including staged outputs.
clean: clean-files
  rm -f "{{explored_file}}" "{{filtered_file}}"
