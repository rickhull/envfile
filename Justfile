set shell := ["bash", "-cu"]

# Interpreted linter extensions managed by activate/deactivate
interpreted := "awk sh bash pl py rb nu nodejs bun deno"

# Build native binaries: go, zig, all, clean (etc)
mod build

# Sets available linters to executable; ensures we have bin/bench
activate: ensure-bench
  #!/usr/bin/env perl
  use strict; use warnings;

  my @impls = (
    [ "bin/lint.awk",    "awk",              "awk --version"              ],
    [ "bin/lint.sh",     "sh",               "sh --version"               ],
    [ "bin/lint.bash",   "bash",             "bash --version"             ],
    [ "bin/lint.pl",     "perl",             "perl --version"             ],
    [ "bin/lint.py",     "python3",          "python3 --version"          ],
    [ "bin/lint.rb",     "ruby",             "ruby --version"             ],
    [ "bin/lint.nu",     "nu (mise)",        "mise exec -- nu --version"  ],
    [ "bin/lint.nodejs", "node (mise)",      "mise exec -- node --version"],
    [ "bin/lint.bun",    "bun (mise)",       "mise exec -- bun --version" ],
    [ "bin/lint.deno",   "deno (mise)",      "mise exec -- deno --version"],
  );

  for my $row (@impls) {
    my ($impl, $runtime, $check) = @$row;
    next unless -f $impl;
    if (system("$check >/dev/null 2>&1") == 0) {
      chmod 0755, $impl;
      print "activated: $impl\n";
    } else {
      chmod 0644, $impl;
      print "skipped:   $impl ($runtime not available)\n";
    }
  }

  # Symlink bin/lint to best available reference impl
  unlink "bin/lint" if -e "bin/lint" or -l "bin/lint";
  for my $candidate (qw(bin/lint.awk bin/lint.pl bin/lint.bash bin/lint.sh)) {
    if (-x $candidate) {
      (my $target = $candidate) =~ s{^bin/}{};
      symlink $target, "bin/lint" or die "symlink: $!\n";
      print "symlinked: bin/lint -> $target\n";
      last;
    }
  }

# Restores pre-activation state (executable bit, symlinks)
deactivate:
  #!/usr/bin/env perl
  use strict; use warnings;

  my %ok = map { $_ => 1 } split ' ', '{{interpreted}}';

  for my $impl (sort glob "bin/lint.*") {
    my ($ext) = $impl =~ /\.([^.]+)$/;
    next unless defined $ext && $ok{$ext};
    chmod 0644, $impl;
    print "deactivated: $impl\n";
  }

  unlink "bin/lint" and print "removed: bin/lint\n" if -e "bin/lint" or -l "bin/lint";

  if (-l "bin/bench" and readlink("bin/bench") eq "pybench") {
    unlink "bin/bench" and print "removed: bin/bench -> pybench\n";
  }

# Set CPU governor to performance and disable turbo boost (run as root / with sudo or run0)
bench-setup:
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
bench-teardown:
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
bench-please:
  sudo chrt -f 99 taskset -c 0 nice -n -20 bin/bench

# Generate reference outputs from the activated reference implementation
generate-reference: activated
  bin/lint spec/accepted.env > spec/accepted.txt 2>&1
  bin/lint spec/rejected.env > spec/rejected.txt 2>&1 || true
  bin/lint spec/warning.env > spec/warning.txt 2>&1
  bin/lint spec/windows.env > spec/windows.txt 2>&1 || true

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
  for f in accepted rejected warning windows; do
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
