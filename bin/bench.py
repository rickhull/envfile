#!/usr/bin/env python3
"""Benchmark env implementations — Welford dynamic warmup, mean+min IPS, CV reporting.

Attempts to reduce scheduler jitter at startup:
  - CPU affinity pinned to current core (os.sched_setaffinity, no privileges)
  - nice -20 (os.setpriority, requires root; EPERM silently ignored)
  - SCHED_FIFO not available from stdlib; use `sudo chrt -f 99` externally
"""

import glob, math, os, subprocess, sys, time

WARMUP_CAP   = 5.0   # seconds
MEASURE_TIME = 2.0   # seconds
WARMUP_BURN  = 5     # unconditional iters before Welford starts
WARMUP_MIN_N = 5     # minimum Welford samples before checking CV
WARMUP_STABLE = 5    # consecutive samples below threshold to declare stable
CV_THRESHOLD = 0.03  # 3%
PATTERN      = "bin/envfile.*"
LANG_TOOL    = "bin/lang"
SHELL_DIR    = "shell/accepted"
NATIVE_DIR   = "native/accepted"
CORPUS_DIR   = "corpus/files"
FILES_FIXTURES = "fixtures"
FILES_CORPUS   = "corpus"


def escalate():
    # Pin to current core — no privileges needed
    try:
        core = os.sched_getaffinity(0)
        current = os.sched_getcpu() if hasattr(os, "sched_getcpu") else min(core)
        os.sched_setaffinity(0, {current})
        print(f"bench.py: pinned to core {current}", file=sys.stderr)
    except (AttributeError, OSError) as e:
        print(f"bench.py: affinity failed: {e}", file=sys.stderr)

    # nice -20
    try:
        os.setpriority(os.PRIO_PROCESS, 0, -20)
        print("bench.py: nice -20", file=sys.stderr)
    except PermissionError:
        pass
    except OSError as e:
        print(f"bench.py: nice failed: {e}", file=sys.stderr)


class Welford:
    __slots__ = ("n", "mean", "m2")

    def __init__(self):
        self.n = 0
        self.mean = 0.0
        self.m2 = 0.0

    def update(self, x):
        self.n += 1
        delta = x - self.mean
        self.mean += delta / self.n
        self.m2 += delta * (x - self.mean)

    def cv(self):
        if self.n < 2 or self.mean == 0:
            return 1.0
        return math.sqrt(self.m2 / (self.n - 1)) / self.mean


def run_once(cmd, spec_files):
    subprocess.run(cmd + spec_files, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def resolve_lang(lang):
    proc = subprocess.run(
        [LANG_TOOL, lang, "envfile"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return None
    path = proc.stdout.strip()
    return path or None


def assemble_paths():
    paths = []
    seen = set()
    for bucket in ("built", "scripted"):
        proc = subprocess.run(
            [LANG_TOOL, "list", bucket],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            raise SystemExit(proc.stderr.strip() or f"bench.py: {LANG_TOOL} list {bucket} failed")
        for lang in proc.stdout.split():
            path = resolve_lang(lang)
            if not path:
                print(f"bench.py: skipping unavailable language {lang}", file=sys.stderr)
                continue
            if path in seen:
                continue
            seen.add(path)
            paths.append(path)
    return paths


def collect_specs(format_name, files_mode):
    specs = []
    if files_mode == FILES_CORPUS:
        for root, dirs, files in os.walk(CORPUS_DIR):
            dirs.sort()
            for name in sorted(files):
                path = os.path.join(root, name)
                if os.path.isfile(path):
                    specs.append(path)
    else:
        spec_dir = NATIVE_DIR if format_name == "native" else SHELL_DIR
        for name in sorted(os.listdir(spec_dir)):
            if name.endswith(".env"):
                path = os.path.join(spec_dir, name)
                if os.path.isfile(path):
                    specs.append(path)
    return specs


def warmup(cmd, spec_files):
    deadline = time.perf_counter() + WARMUP_CAP
    total = 0

    # burn-in: discard cold-start samples
    for _ in range(WARMUP_BURN):
        run_once(cmd, spec_files)
        total += 1
        if time.perf_counter() >= deadline:
            return total, 1.0

    # Welford stability loop
    w = Welford()
    stable_n = 0
    while True:
        t0 = time.perf_counter()
        run_once(cmd, spec_files)
        lat = time.perf_counter() - t0
        w.update(lat)
        total += 1

        if w.n >= WARMUP_MIN_N and w.cv() < CV_THRESHOLD:
            stable_n += 1
            if stable_n >= WARMUP_STABLE:
                break
        else:
            stable_n = 0

        if time.perf_counter() >= deadline:
            break

    return total, w.cv()


def measure(cmd, spec_files):
    w = Welford()
    min_lat = float("inf")
    deadline = time.perf_counter() + MEASURE_TIME
    t0 = time.perf_counter()

    while True:
        ts = time.perf_counter()
        run_once(cmd, spec_files)
        t1 = time.perf_counter()
        lat = t1 - ts
        w.update(lat)
        if lat < min_lat:
            min_lat = lat
        if t1 >= deadline:
            break

    elapsed = time.perf_counter() - t0
    ips_mean = w.n / elapsed
    ips_min  = 1.0 / min_lat
    return w.n, elapsed, ips_mean, ips_min, w.cv()


def label(path):
    ext = os.path.splitext(path)[1]
    return ext.lstrip(".") if ext else os.path.basename(path)


def main():
    escalate()

    format_name = "shell"
    files_mode = FILES_FIXTURES
    impl_args = []

    for arg in sys.argv[1:]:
        if arg.startswith("format="):
            format_name = arg.split("=", 1)[1]
        elif arg.startswith("files="):
            files_mode = arg.split("=", 1)[1]
        else:
            impl_args.append(arg)

    if format_name not in ("shell", "native"):
        print(f"bench.py: unsupported format: {format_name}", file=sys.stderr)
        sys.exit(1)
    if files_mode not in (FILES_FIXTURES, FILES_CORPUS):
        print(f"bench.py: unsupported files: {files_mode}", file=sys.stderr)
        sys.exit(1)

    if impl_args:
        paths = []
        for p in impl_args:
            if glob.fnmatch.fnmatch(p, PATTERN):
                paths.append(p)
                continue
            path = None
            if os.sep not in p and "/" not in p:
                path = resolve_lang(p)
            if path:
                paths.append(path)
            else:
                print(f"bench.py: {p}: does not match {PATTERN} and is not a runnable language, skipping", file=sys.stderr)
    else:
        paths = assemble_paths()

    spec_files = collect_specs(format_name, files_mode)

    if not paths:
        print("bench.py: no executable implementations found", file=sys.stderr)
        sys.exit(1)

    results = []
    for path in paths:
        cmd  = [path]
        name = label(path)
        print(f"benching {path}...", end="", flush=True)
        wu_n, wu_cv = warmup(cmd, spec_files)
        count, elapsed, ips_mean, ips_min, cv = measure(cmd, spec_files)
        print(f"  warmup={wu_n}(cv={wu_cv*100:.1f}%)"
              f"  {count} iters in {elapsed:.2f}s"
              f" (mean={ips_mean:.1f} min={ips_min:.1f} i/s, cv={cv*100:.1f}%)")
        results.append((name, ips_mean, ips_min, cv))

    results.sort(key=lambda r: r[1], reverse=True)

    # baseline: prefer awk, fallback sh, fallback fastest
    base = next((r for r in results if r[0] == "awk"), None)
    if base is None:
        base = next((r for r in results if r[0] == "sh"), None)
    if base is None:
        base = results[0]
    base_name, base_mean = base[0], base[1]

    print()
    print(f"{'validator':<12}  {'mean i/s':>10}  {'min i/s':>10}  {'cv%':>6}  {'vs awk(mean)':>14}")
    print(f"{'--------':<12}  {'--------':>10}  {'-------':>10}  {'---':>6}  {'------------':>14}")
    for name, ips_mean, ips_min, cv in results:
        cv_s = f"{cv*100:.1f}%"
        if name == base_name:
            rel = "(baseline)"
        elif ips_mean > base_mean:
            rel = f"{ips_mean/base_mean:.2f}x faster"
        else:
            rel = f"{base_mean/ips_mean:.2f}x slower"
        print(f"{name:<12}  {ips_mean:>10.1f}  {ips_min:>10.1f}  {cv_s:>6}  {rel:>14}")


if __name__ == "__main__":
    main()
