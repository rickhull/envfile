set shell := ["bash", "-cu"]

corpus_dir    := "corpus/files"
scores_file   := "corpus/scores.txt"
explored_file := "corpus/explored.txt"
filtered_file := "corpus/filtered.txt"
max_filesize  := "5K"

blacklist := '(secret|\.secret\.)|(\.(js|ts|jsx|tsx|mjs|cjs|json|jsonl|jsonc|yaml|yml|toml|md|svg|png|ico|jpg|gif|wav|beam|roc|zig|rs|rb|ex|exs|erl|hrl|db|db-wal|db-journal|def|result-ast|elixir|elixir_scm|app|app_cache|appup|lock|log|heex|eex|snap|css|html|xml|po|pot|sql|tar|gz|xz|zst|lzma|bin|pem|crt|der|sig|so|o|a|dylib|dll|exe|go|py|pl|pm|mo|cmake|pc|mod|ri|dyn_hi|elc|tablet|md5sums|list|triggers|shlibs|h|c|cpp|hpp|s|S|pak|xpm|rbs|scm|asn1|pub|pbm|hex|symbols|[0-9])$)'

exclude_globs := "-g !.git/ -g !node_modules/ -g !__pycache__/ -g !vendor/ -g !target/ -g !/proc/ -g !/sys/ -g !/dev/ -g !/run/ -g !/tmp/"

shellconf_patterns := '(?i)(.*conf.*\.sh)$'

rg_files := "rg --files --no-messages --no-ignore --hidden --one-file-system"

# Collect real-world env files from the local filesystem.
#
# Each pipeline composes three stages:
#   1. explore  — find candidate files (by directory walk, systemd refs, or filename patterns)
#   2. filter   — lint each candidate, keep those passing size-tiered acceptance thresholds
#   3. collect  — sanitize sensitive lines, copy to corpus/files/ (chroot layout), score directories
#
# Pipelines can be run individually or combined via `generate`.

# Run all pipelines (systemd, shellconf, root)
generate: systemd root shellconf

# Pipeline: $HOME
home:
  @just corpus explore_home
  @just corpus filter
  @just corpus collect
  mv corpus/scores.txt corpus/home.scores.txt

# Pipeline: root (/)
root:
  @just corpus explore_root
  @just corpus filter
  @just corpus collect
  mv corpus/scores.txt corpus/root.scores.txt

# Pipeline: systemd *.service files: EnvironmentFile=
systemd:
  @just corpus explore_systemd
  @just corpus filter
  @just corpus collect
  mv corpus/scores.txt corpus/systemd.scores.txt

# Pipeline: *conf*.sh filename pattern
shellconf:
  @just corpus explore_shellconf
  @just corpus filter
  @just corpus collect
  mv corpus/scores.txt corpus/shellconf.scores.txt

# --- Explore -----------------------------------------------------------------

# Find candidates under $HOME
explore_home: (explore "$HOME")

# Find candidates across the entire filesystem
explore_root: (explore "/")

# Find candidate env-like files under a directory
explore dir="/" glob="":
  #!/usr/bin/env bash
  dir="{{dir}}"
  glob="{{glob}}"

  {{rg_files}} \
    --max-filesize "{{max_filesize}}" \
    ${glob:+-g "$glob"} \
    {{exclude_globs}} \
    "$dir" \
  | rg -vi "{{blacklist}}" \
  | rg -vF "$(pwd)/" \
  | sort \
  | xargs -d '\n' rg --no-messages -l '=' \
  > "{{explored_file}}"

  count=$(wc -l < {{explored_file}})
  msg="Qualified ${count} files (${dir}) under {{max_filesize}} file size"
  printf 'explore:\t%s\n' "$msg"
  printf '\t\tWrote {{explored_file}}\n'

# Find shell config files matching *Conf.sh (case insensitive)
explore_shellconf:
  #!/usr/bin/env bash
  {{rg_files}} \
    --max-filesize "{{max_filesize}}" \
    --glob-case-insensitive \
    -g "!*.service" \
    {{exclude_globs}} \
    / \
  | rg -i "{{shellconf_patterns}}" \
  | rg -vF "$(pwd)/" \
  | xargs -d '\n' rg --no-messages -l '=' \
  > "{{explored_file}}"

  count=$(wc -l < {{explored_file}})
  msg="Qualified ${count} files matching shellconf patterns"
  printf 'explore_shellconf:\t%s\n' "$msg"
  printf '\t\tWrote {{explored_file}}\n'

# Chase EnvironmentFile= refs from systemd unit files
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

  with open(explored_file, "w") as f:
    for ref in sorted(refs):
      f.write(ref + "\n")

  msg = f"Found {len(units)} unit files, qualified {len(refs)} EnvironmentFile refs"
  print(f"explore_systemd:\t{msg}")
  print(f"\t\tWrote {explored_file}")

# --- Filter ------------------------------------------------------------------

# Lint explored files, keep those passing acceptance thresholds
filter:
  #!/usr/bin/env python3
  import os, re, subprocess, sys
  from collections import defaultdict

  explored_file = "{{explored_file}}"
  filtered_file = "{{filtered_file}}"

  for linter in ("bin/lint.asm", "bin/lint.c", "bin/lint.zig"):
    if os.access(linter, os.X_OK):
      break
  else:
    print("filter: \tno native linter found — run `just build c` or similar", file=sys.stderr)
    raise SystemExit(1)

  summary_re  = re.compile(r"(\d+) checked, (\d+) errors, (\d+) warnings")
  overlay_re  = re.compile(r"overlay/[0-9a-f]{64}/diff(/.*)")
  seen_logical = set()
  accepted = skipped = 0

  def logical_key(path):
    m = overlay_re.search(path)
    return m.group(1) if m else path

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
      key = logical_key(path)
      if key in seen_logical:
        skipped += 1
        continue
      r = subprocess.run([linter, path], capture_output=True)
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
      seen_logical.add(key)
      out.write(path + "\n")
      accepted += 1

  msg = f"Accepted {accepted} files, {linter} skipped {skipped}"
  print(f"filter: \t{msg}")
  print(f"\t\tWrote {filtered_file}")

# --- Collect ------------------------------------------------------------------

# Sanitize sensitive lines, copy to corpus/files/, score directories
collect: &&chown
  #!/usr/bin/env python3
  import os, re, random, shutil, sys
  from collections import defaultdict

  filtered_file = "{{filtered_file}}"
  dest          = "{{corpus_dir}}"
  scores_file   = "{{scores_file}}"

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
  dir_scores = defaultdict(int)
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
      dir_scores[os.path.dirname(path)] += 1
      accepted += 1

  with open(scores_file, "w") as f:
    for d, score in sorted(dir_scores.items(), key=lambda x: -x[1]):
      f.write(f"{score:>5}  {d}\n")

  print(f"collect:\tSanitized {accepted} files to {dest}/")
  msg = f"Scored {len(dir_scores)} dirs"
  print(f"scores: \t{msg}")
  print(f"\t\tWrote {scores_file}")
  overlay_re = re.compile(r"overlay/[0-9a-f]{64}/diff(/.*)")
  top = sorted(dir_scores.items(), key=lambda x: -x[1])
  for d, score in top[:5]:
    if overlay_re.search(d):
      continue
    print(f"{score:>5}  {d}")

# --- Housekeeping -------------------------------------------------------------

# Assign corpus file ownership to repo owner / operator
chown:
  @chown -R "$(id -un):$(id -gn)" {{corpus_dir}}/

# Remove corpus output files
clean-files:
  rm -f "{{scores_file}}"
  find {{corpus_dir}} -mindepth 1 -delete

# Remove all corpus state (files, scores, explored, filtered)
clean: clean-files
  rm -f "{{explored_file}}" "{{filtered_file}}"
