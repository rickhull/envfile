# Benchmark Jitter

## The problem

The benchmarks in this project measure process invocation throughput — how many
times per second a given validator can be launched, run, and reaped. At the fast
end (asm, C, Zig, Rust), each iteration takes 0.4–1ms. At that timescale, the
Linux scheduler is a significant source of noise.

### Sources of jitter

**Scheduler preemption.** The kernel can preempt the benchmarking process at
any point — mid-fork, mid-exec, mid-wait. A single 1ms preemption on a 0.5ms
iteration inflates that sample by 200%. Fast impls are disproportionately
affected because preemption is a larger fraction of their runtime.

**CPU frequency scaling.** Modern CPUs run at variable frequencies under the
default `powersave` or `schedutil` governor. A core that boosts to 4.5GHz for
one iteration and drops to 3.2GHz for the next produces ~40% latency variance
with no other cause.

**Turbo boost.** Short-burst frequency elevation (Intel Turbo, AMD Boost)
depends on thermal headroom and package load. Results vary between a cold and
warm chip, and between runs on the same day.

**Process migration.** Without CPU affinity, the scheduler may move the
benchmarking process between cores between iterations. Each migration pays a
cold L1/L2 cache penalty.

**Shared system activity.** Background daemons, timers, kernel threads, and
other user processes compete for the same cores, introducing unpredictable
latency spikes.

### How it manifests

The `cv%` column in the current benchmark output quantifies it directly. Slow
impls (bun, deno, nu) show 2–5% CV because scheduler noise is small relative
to their ~50–85ms runtime. Fast impls (asm, C, Zig, Rust) show 10–25% CV
because the same absolute noise is a large fraction of their ~0.4–1ms runtime.

The `min i/s` column approximates noise-free throughput: the minimum observed
latency is the sample where the scheduler happened not to preempt. The gap
between `mean i/s` and `min i/s` is a rough measure of how much jitter is
inflating the mean.

The dynamic warmup (Welford CV stability) helps by waiting for the filesystem
cache, dynamic linker maps, and branch predictor to reach steady state before
measuring. But it cannot eliminate scheduler noise — that requires the
mitigations below.

---

## Mitigations

Each mitigation reduces a specific noise source. They are independent and
cumulative. More invasive options are noted.

### `taskset` — CPU affinity

Pin the benchmark process to a single core. Eliminates migration cost and
ensures all iterations run on the same L1/L2 cache.

```sh
taskset -c 2 bin/bench
```

No privileges required. Choose a core that is otherwise idle. Does not prevent
the scheduler from preempting on that core, but removes the migration penalty.

### `nice` — scheduler priority

Lower the nice value of the benchmark process to reduce its chance of being
preempted by other user-space work.

```sh
sudo nice -n -20 bin/bench
```

Without `sudo`, you can only raise the nice value (lower priority), which is
useful if you want to deprioritize other tasks instead:

```sh
# in another terminal, deprioritize everything else
renice -n 19 -p $(pgrep -d' ' -u $USER)
```

Modest effect. Does not help against kernel threads or real-time processes.

### `chrt` — real-time scheduling policy

Run the benchmark under `SCHED_FIFO`, which prevents preemption by normal
scheduler tasks on the same core. The most effective user-accessible mitigation
short of CPU isolation.

```sh
sudo chrt -f 99 bin/bench
```

Requires root. Use with care — a runaway `SCHED_FIFO` process at priority 99
can starve the system. Safe for short benchmark runs; do not leave running
unattended.

Combining with `taskset` is effective:

```sh
sudo chrt -f 99 taskset -c 2 bin/bench
```

### CPU frequency governor — `/sys/devices`

Switch the CPU frequency scaling governor from `powersave`/`schedutil` to
`performance`, which fixes the frequency at maximum and disables turbo
variation.

```sh
# set performance governor on all cores
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# optionally disable turbo boost (Intel)
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo

# restore on reboot, or manually:
echo powersave | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
```

Requires root. Reverts on reboot. Reduces CV significantly for fast impls by
eliminating frequency jitter. Does not affect scheduling.

### `isolcpus` — kernel CPU isolation

Reserve one or more cores for exclusive use by pinning processes to them. The
kernel scheduler places no other tasks on isolated cores, eliminating
preemption almost entirely.

Configured via kernel boot parameter in `/etc/default/grub`:

```
GRUB_CMDLINE_LINUX="isolcpus=3"
```

Then `update-grub` and reboot. Use with `taskset -c 3`.

This is the most effective mitigation for low-noise measurement of fast
processes. It is also the most invasive: requires a kernel parameter change and
reboot, and permanently removes that core from general-purpose scheduling.
**Not recommended for general workstations.** Worth considering on a dedicated
benchmark machine.

---

## Practical combinations

For a quick, low-effort improvement (no reboot, no config changes):

```sh
taskset -c 2 bin/bench
```

For serious measurement on a developer machine:

```sh
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
sudo chrt -f 99 taskset -c 2 bin/bench
```

Restore frequency governor afterward if desired.

---

## Tradeoffs summary

| Mitigation | Privilege | Invasiveness | Effect |
|---|---|---|---|
| `taskset` | none | none | eliminates migration, small win |
| `nice` | sudo for negative values | none | modest, helps vs user processes |
| `chrt -f 99` | sudo | none (reverts) | large win, eliminates user preemption |
| frequency governor | sudo | reverts on reboot | large win, eliminates frequency jitter |
| `isolcpus` | root + reboot | permanent config change | near-elimination of scheduler noise |
