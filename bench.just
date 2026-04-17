# Set CPU governor to performance and disable turbo boost (run as root / with sudo or run0)
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

# Restore CPU governor to powersave and re-enable turbo boost (run0 / sudo)
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

# Run bench with elevated privileges (run0 / sudo)
please:
  chrt -f 99 taskset -c 0 nice -n -20 bin/bench

