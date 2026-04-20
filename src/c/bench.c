/* bench.c — benchmark env validator implementations
 *
 * Globs bin/envfile* plus bin/nullscan, filters on executable bit, runs each
 * against shell/*.env or native/*.env.  Warmup: dynamic via Welford CV
 * stability, capped at 5s.
 * Measurement: count iterations over ~2s window; tracks mean and minimum
 * latency.  Reports both mean- and min-based IPS with CV.
 *
 * At startup, attempts to reduce scheduler jitter via:
 *   - SCHED_FIFO real-time scheduling (requires root)
 *   - CPU affinity pinned to current core (no privileges needed)
 *   - nice -20 (requires root)
 * Each is attempted independently; EPERM is silently ignored.
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <fnmatch.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define WARMUP_CAP_NS     5000000000LL  /* 5s wall-clock cap */
#define WARMUP_ITER_CAP   999           /* hard iter cap in case one iter is very slow */
#define MEASURE_NS        2000000000LL  /* 2s */
#define WARMUP_BURN_IN    5             /* unconditional iters before Welford starts */
#define WARMUP_MIN_N      5             /* minimum Welford samples before first checkpoint */
#define WARMUP_SAMPLE_N   10            /* checkpoint every Nth sample */
#define WARMUP_SLOPE_STR  5             /* consecutive checkpoints with subpar improvement */
#define CV_SLOPE_THRESH   0.005         /* improvement < 0.5pp per sample = subpar */
#define CV_THRESHOLD      0.03          /* 3%: original absolute exit still applies */
#define IMPL_DIR       "bin"
#define SHELL_DIR      "shell"
#define NATIVE_DIR     "native"
#define SHELL_EXT      ".env"
#define FORMAT_SHELL   "shell"
#define FORMAT_NATIVE  "native"
#define MAX_IMPLS      64
#define MAX_SPECS      16
#define MAX_CORPUS     4096
#define CORPUS_DIR     "corpus/files"
#define FILES_FIXTURES "fixtures"
#define FILES_CORPUS   "corpus"

typedef struct { long long n; double cv; } WarmupResult;

static void escalate(void) {
    /* Pin to current core — keeps us on one cache, no migration penalty.
     * Uses sched_getcpu() to find current core, then pins affinity there. */
    int core = sched_getcpu();
    if (core >= 0) {
        cpu_set_t mask;
        CPU_ZERO(&mask);
        CPU_SET(core, &mask);
        if (sched_setaffinity(0, sizeof(mask), &mask) == 0)
            fprintf(stderr, "bench: pinned to core %d\n", core);
        else
            fprintf(stderr, "bench: taskset failed: %s\n", strerror(errno));
    }

    /* SCHED_FIFO priority 99 — prevents preemption by normal tasks. */
    struct sched_param sp = { .sched_priority = 99 };
    if (sched_setscheduler(0, SCHED_FIFO, &sp) == 0)
        fprintf(stderr, "bench: SCHED_FIFO priority 99\n");
    else if (errno != EPERM)
        fprintf(stderr, "bench: chrt failed: %s\n", strerror(errno));

    /* nice -20 — deprioritises competing user-space processes. */
    if (setpriority(PRIO_PROCESS, 0, -20) == 0)
        fprintf(stderr, "bench: nice -20\n");
    else if (errno != EPERM)
        fprintf(stderr, "bench: nice failed: %s\n", strerror(errno));
}

typedef struct {
    char   *name;
    double  ips_mean;
    double  ips_min;
    double  cv;
} Result;

/* Welford online mean/variance accumulator */
typedef struct { long long n; double mean, m2; } Welford;

static void welford_update(Welford *w, double x) {
    w->n++;
    double delta = x - w->mean;
    w->mean += delta / (double)w->n;
    w->m2   += delta * (x - w->mean);
}

static double welford_cv(const Welford *w) {
    if (w->n < 2 || w->mean == 0) return 1.0;
    double var = w->m2 / (double)(w->n - 1);
    return sqrt(var) / w->mean;
}

static long long now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void run_once(const char *impl, const char *format, char **specs, int nspecs) {
    pid_t pid = fork();
    if (pid == 0) {
        int extra = strcmp(impl, "bin/envfile") == 0 ? 4 : 2;
        char **argv = malloc((extra + nspecs) * sizeof(char *));
        if (strcmp(impl, "bin/envfile") == 0) {
            argv[0] = (char *)impl;
            argv[1] = (char *)(strcmp(format, FORMAT_NATIVE) == 0 ? "format=native" : "format=shell");
            argv[2] = "action=validate";
            for (int i = 0; i < nspecs; i++) argv[3 + i] = specs[i];
            argv[3 + nspecs] = NULL;
        } else {
            argv[0] = (char *)impl;
            for (int i = 0; i < nspecs; i++) argv[1 + i] = specs[i];
            argv[1 + nspecs] = NULL;
        }
        setenv("ENVFILE_FORMAT", format, 1);
        setenv("ENVFILE_ACTION", "validate", 1);
        int devnull = open("/dev/null", O_WRONLY);
        dup2(devnull, STDOUT_FILENO);
        dup2(devnull, STDERR_FILENO);
        execvp(impl, argv);
        _exit(1);
    }
    waitpid(pid, NULL, 0);
}

static WarmupResult
warmup_phase(const char *impl, const char *format, char **specs, int nspecs) {
    long long t_cap = now_ns() + WARMUP_CAP_NS;
    long long total = 0;

    /* burn-in: run unconditionally, no stats collected */
    for (int i = 0; i < WARMUP_BURN_IN; i++) {
        run_once(impl, format, specs, nspecs);
        total++;
        if (now_ns() >= t_cap || total >= WARMUP_ITER_CAP) goto done;
    }

    /* stability loop: exit when CV stops improving or drops below threshold */
    {
        Welford w = {0};
        double prev_cv = 1.0;
        int    slope_streak = 0;
        while (1) {
            long long t0 = now_ns();
            run_once(impl, format, specs, nspecs);
            total++;
            double lat_ns = (double)(now_ns() - t0);
            welford_update(&w, lat_ns);

            double cv = welford_cv(&w);

            /* absolute exit: CV already low enough */
            if (w.n >= WARMUP_MIN_N && cv < CV_THRESHOLD) break;

            /* slope exit: every WARMUP_SAMPLE_N samples, check improvement */
            if (w.n >= WARMUP_MIN_N && w.n % WARMUP_SAMPLE_N == 0) {
                double improvement = prev_cv - cv;  /* positive = improving */
                if (improvement < CV_SLOPE_THRESH)
                    slope_streak++;
                else
                    slope_streak = 0;
                prev_cv = cv;
                if (slope_streak >= WARMUP_SLOPE_STR) break;
            }

            if (now_ns() >= t_cap || total >= WARMUP_ITER_CAP) break;
        }
        return (WarmupResult){ total, welford_cv(&w) };
    }
done:
    return (WarmupResult){ total, 1.0 };
}

static Result bench_one(const char *impl, const char *format, char **specs, int nspecs) {
    printf("benching %s...", impl);
    fflush(stdout);

    WarmupResult wu = warmup_phase(impl, format, specs, nspecs);

    long long t0 = now_ns(), t1 = t0;
    long long count = 0;
    Welford w = {0};
    double min_ns = 1e18;

    while (1) {
        long long ts = now_ns();
        run_once(impl, format, specs, nspecs);
        t1 = now_ns();
        double lat_ns = (double)(t1 - ts);
        welford_update(&w, lat_ns);
        if (lat_ns < min_ns) min_ns = lat_ns;
        count++;
        if (t1 - t0 >= MEASURE_NS) break;
    }

    double elapsed   = (double)(t1 - t0) / 1e9;
    double ips_mean  = (double)count / elapsed;
    double ips_min   = 1e9 / min_ns;
    double cv        = welford_cv(&w);

    printf("  warmup=%lld(cv=%.1f%%)  %lld iters in %.2fs"
           " (mean=%.1f min=%.1f i/s, cv=%.1f%%)\n",
           wu.n, wu.cv * 100.0, count, elapsed,
           ips_mean, ips_min, cv * 100.0);

    const char *name = impl;
    static const char *prefixes[] = { "bin/envfile.", "bin/envfile-", "bin/", NULL };
    for (int i = 0; prefixes[i]; i++) {
        size_t pl = strlen(prefixes[i]);
        if (strncmp(impl, prefixes[i], pl) == 0) { name = impl + pl; break; }
    }
    Result r;
    r.name     = strdup(name);
    r.ips_mean = ips_mean;
    r.ips_min  = ips_min;
    r.cv       = cv;
    return r;
}

static int collect_corpus(const char *dir, char **out, int *n, int max) {
    DIR *d = opendir(dir);
    if (!d) return -1;
    struct dirent *e;
    while ((e = readdir(d)) && *n < max) {
        if (e->d_name[0] == '.') continue;
        char buf[1024];
        snprintf(buf, sizeof(buf), "%s/%s", dir, e->d_name);
        if (e->d_type == DT_DIR) {
            collect_corpus(buf, out, n, max);
        } else if (e->d_type == DT_REG) {
            out[(*n)++] = strdup(buf);
        }
    }
    closedir(d);
    return 0;
}

static int cmp_result_desc(const void *a, const void *b) {
    double da = ((Result *)a)->ips_mean, db = ((Result *)b)->ips_mean;
    return (da < db) - (da > db);
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(char **)a, *(char **)b);
}

int main(int argc, char *argv[]) {
    const char *format = FORMAT_SHELL;
    const char *files  = FILES_FIXTURES;

    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "format=", 7) == 0) {
            format = argv[i] + 7;
        } else if (strncmp(argv[i], "files=", 6) == 0) {
            files = argv[i] + 6;
        } else {
            fprintf(stderr, "bench: unsupported arg: %s\n", argv[i]);
            return 1;
        }
    }
    if (strcmp(format, FORMAT_SHELL) != 0 && strcmp(format, FORMAT_NATIVE) != 0) {
        fprintf(stderr, "bench: unsupported format: %s\n", format);
        return 1;
    }
    if (strcmp(files, FILES_FIXTURES) != 0 && strcmp(files, FILES_CORPUS) != 0) {
        fprintf(stderr, "bench: unsupported files: %s\n", files);
        return 1;
    }

    escalate();

    /* collect spec files */
    int use_corpus = strcmp(files, FILES_CORPUS) == 0;
    char **specs;
    int    nspecs  = 0;
    if (use_corpus) {
        specs = malloc(MAX_CORPUS * sizeof(char *));
        if (!specs) { perror("malloc"); return 1; }
        if (collect_corpus(CORPUS_DIR, specs, &nspecs, MAX_CORPUS) < 0) {
            fprintf(stderr, "bench: cannot open %s: %s\n", CORPUS_DIR, strerror(errno));
            return 1;
        }
        qsort(specs, nspecs, sizeof(char *), cmp_str);
    } else {
        specs = malloc(MAX_SPECS * sizeof(char *));
        if (!specs) { perror("malloc"); return 1; }
        const char *spec_dir = strcmp(format, FORMAT_NATIVE) == 0 ? NATIVE_DIR : SHELL_DIR;
        DIR *d = opendir(spec_dir);
        if (!d) {
            fprintf(stderr, "bench: cannot open %s: %s\n", spec_dir, strerror(errno));
            return 1;
        }
        struct dirent *e;
        while ((e = readdir(d)) && nspecs < MAX_SPECS) {
            if (e->d_type != DT_REG) continue;
            int nl = strlen(e->d_name), xl = strlen(SHELL_EXT);
            if (nl <= xl || strcmp(e->d_name + nl - xl, SHELL_EXT) != 0) continue;
            char buf[512];
            snprintf(buf, sizeof(buf), "%s/%s", spec_dir, e->d_name);
            specs[nspecs++] = strdup(buf);
        }
        closedir(d);
        qsort(specs, nspecs, sizeof(char *), cmp_str);
    }

    /* collect executable validator impls */
    char *impls[MAX_IMPLS]; int nimpls = 0;
    {
        DIR *d = opendir(IMPL_DIR);
        if (!d) {
            fprintf(stderr, "bench: cannot open %s: %s\n", IMPL_DIR, strerror(errno));
            return 1;
        }
        struct dirent *e;
        while ((e = readdir(d)) && nimpls < MAX_IMPLS) {
            char buf[512];
            snprintf(buf, sizeof(buf), "%s/%s", IMPL_DIR, e->d_name);
            if (access(buf, X_OK) != 0) continue;
            if (fnmatch("envfile*", e->d_name, 0) != 0 &&
                strcmp(e->d_name, "nullscan") != 0) continue;
            impls[nimpls++] = strdup(buf);
        }
        closedir(d);
        qsort(impls, nimpls, sizeof(char *), cmp_str);
    }

    if (nimpls == 0) {
        printf("no executable validators found for %s in %s/\n", format, IMPL_DIR);
        return 1;
    }

    if (nspecs == 0) {
        printf("no files found for format=%s files=%s\n", format, files);
        return 1;
    }

    /* benchmark each */
    Result results[MAX_IMPLS];
    for (int i = 0; i < nimpls; i++)
        results[i] = bench_one(impls[i], format, specs, nspecs);

    qsort(results, nimpls, sizeof(Result), cmp_result_desc);

    /* find baseline: prefer format-specific reference, fallback sh, fallback fastest */
    double base_ips = results[0].ips_mean;
    const char *base_name = results[0].name;
    const char *preferred = "awk";
    for (int i = 0; i < nimpls; i++) {
        if (strcmp(results[i].name, preferred) == 0) {
            base_ips = results[i].ips_mean; base_name = results[i].name; break;
        }
    }
    if (strcmp(base_name, preferred) != 0) {
        for (int i = 0; i < nimpls; i++) {
            if (strcmp(results[i].name, "sh") == 0) {
                base_ips = results[i].ips_mean; base_name = results[i].name; break;
            }
        }
    }

    printf("\nformat=%-6s  files=%-8s  (%d files/invoke)\n\n",
           format, files, nspecs);
    printf("%-12s  %10s  %10s  %6s  %14s\n",
           "validator", "mean i/s", "min i/s", "cv%", "vs awk(mean)");
    printf("%-12s  %10s  %10s  %6s  %14s\n",
           "--------", "--------", "-------", "---", "------------");
    for (int i = 0; i < nimpls; i++) {
        Result *r = &results[i];
        if (strcmp(r->name, base_name) == 0) {
            printf("%-12s  %10.1f  %10.1f  %5.1f%%  %14s\n",
                   r->name, r->ips_mean, r->ips_min, r->cv * 100.0, "(baseline)");
        } else if (r->ips_mean > base_ips) {
            printf("%-12s  %10.1f  %10.1f  %5.1f%%  %10.2fx faster\n",
                   r->name, r->ips_mean, r->ips_min, r->cv * 100.0,
                   r->ips_mean / base_ips);
        } else {
            printf("%-12s  %10.1f  %10.1f  %5.1f%%  %10.2fx slower\n",
                   r->name, r->ips_mean, r->ips_min, r->cv * 100.0,
                   base_ips / r->ips_mean);
        }
    }
    return 0;
}
