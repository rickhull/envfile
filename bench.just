# Set CPU governor to performance and disable turbo boost.
setup:
  #!/usr/bin/env bash
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$gov"
  done
  echo "governors set to performance"
  if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo
    echo "intel turbo disabled"
  fi

# Restore CPU governor to powersave and re-enable turbo boost.
teardown:
  #!/usr/bin/env bash
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo powersave > "$gov"
  done
  echo "governors restored to powersave"
  if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo
    echo "intel turbo enabled"
  fi

# Run the benchmark binary with elevated privileges.
run *args:
  chrt -f 99 taskset -c 0 nice -n -20 bench {{args}} || bench {{args}}

# Run shell-format benchmarks.
shell *args:
  chrt -f 99 taskset -c 0 nice -n -20 bench format=shell {{args}} || bench format=shell {{args}}

# Run native-format benchmarks.
native *args:
  chrt -f 99 taskset -c 0 nice -n -20 bench format=native {{args}} || bench format=native {{args}}

# Run the benchmark over the shared corpus with the default strict format.
corpus *args:
  chrt -f 99 taskset -c 0 nice -n -20 bench files=corpus {{args}} || bench files=corpus {{args}}

# Run shell-format benchmarks over the shared corpus.
shell_corpus *args:
  chrt -f 99 taskset -c 0 nice -n -20 bench format=shell files=corpus {{args}} || bench format=shell files=corpus {{args}}

# Run native-format benchmarks over the shared corpus.
native_corpus *args:
  chrt -f 99 taskset -c 0 nice -n -20 bench format=native files=corpus {{args}} || bench format=native files=corpus {{args}}

# Compare nullscan argv and stdin modes over the shared corpus.
nullscan:
  #!/usr/bin/env bash
  set -euo pipefail

  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/nullscan-bench.XXXXXX")
  trap 'rm -rf "$tmpdir"' EXIT

  mapfile -t files < <(find corpus/files -type f | sort)
  printf '%s\n' "${files[@]}" > "$tmpdir/files"

  nullscan "${files[@]}" > "$tmpdir/argv.out"
  nullscan < "$tmpdir/files" > "$tmpdir/stdin.out"

  diff -u "$tmpdir/argv.out" "$tmpdir/stdin.out"
