/* bench.c — benchmark env linter implementations
 *
 * Globs bin/lint.*, filters on executable bit, runs each against
 * spec/*.env.  Warmup: dynamic via Welford CV stability, capped at 5s.
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
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define WARMUP_CAP_NS  5000000000LL  /* 5s cap */
#define MEASURE_NS     2000000000LL  /* 2s */
#define WARMUP_BURN_IN 5             /* unconditional iters before Welford starts */
#define WARMUP_MIN_N   5             /* minimum Welford samples before checking CV */
#define WARMUP_STABLE  5             /* consecutive samples below threshold */
#define CV_THRESHOLD   0.03          /* 3% */
#define LINTER_DIR     "bin"
#define LINTER_PFX     "lint."
#define SPEC_DIR       "spec"
#define SPEC_EXT       ".env"
#define MAX_IMPLS      64
#define MAX_SPECS      16

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

static void run_once(const char *impl, char **specs, int nspecs) {
    pid_t pid = fork();
    if (pid == 0) {
        char **argv = malloc((2 + nspecs) * sizeof(char *));
        argv[0] = (char *)impl;
        for (int i = 0; i < nspecs; i++) argv[1 + i] = specs[i];
        argv[1 + nspecs] = NULL;
        int devnull = open("/dev/null", O_WRONLY);
        dup2(devnull, STDOUT_FILENO);
        dup2(devnull, STDERR_FILENO);
        execvp(impl, argv);
        _exit(1);
    }
    waitpid(pid, NULL, 0);
}

static WarmupResult
warmup_phase(const char *impl, char **specs, int nspecs) {
    long long t_cap = now_ns() + WARMUP_CAP_NS;
    long long total = 0;

    /* burn-in: run unconditionally, no stats collected */
    for (int i = 0; i < WARMUP_BURN_IN; i++) {
        run_once(impl, specs, nspecs);
        total++;
        if (now_ns() >= t_cap) goto done;
    }

    /* stability loop: Welford until CV stable or cap hit */
    {
        Welford w = {0};
        int stable_n = 0;
        while (1) {
            long long t0 = now_ns();
            run_once(impl, specs, nspecs);
            total++;
            double lat_ns = (double)(now_ns() - t0);
            welford_update(&w, lat_ns);

            if (w.n >= WARMUP_MIN_N && welford_cv(&w) < CV_THRESHOLD) {
                if (++stable_n >= WARMUP_STABLE) break;
            } else {
                stable_n = 0;
            }

            if (now_ns() >= t_cap) break;
        }
        return (WarmupResult){ total, welford_cv(&w) };
    }
done:
    return (WarmupResult){ total, 1.0 };
}

static Result bench_one(const char *impl, char **specs, int nspecs) {
    printf("benching %s...", impl);
    fflush(stdout);

    WarmupResult wu = warmup_phase(impl, specs, nspecs);

    long long t0 = now_ns(), t1 = t0;
    long long count = 0;
    Welford w = {0};
    double min_ns = 1e18;

    while (1) {
        long long ts = now_ns();
        run_once(impl, specs, nspecs);
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

    const char *ext = strrchr(impl, '.');
    Result r;
    r.name     = ext ? strdup(ext + 1) : strdup(impl);
    r.ips_mean = ips_mean;
    r.ips_min  = ips_min;
    r.cv       = cv;
    return r;
}

static int cmp_result_desc(const void *a, const void *b) {
    double da = ((Result *)a)->ips_mean, db = ((Result *)b)->ips_mean;
    return (da < db) - (da > db);
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(char **)a, *(char **)b);
}

int main(void) {
    escalate();

    /* collect spec files */
    char *specs[MAX_SPECS]; int nspecs = 0;
    {
        DIR *d = opendir(SPEC_DIR);
        struct dirent *e;
        while ((e = readdir(d)) && nspecs < MAX_SPECS) {
            if (e->d_type != DT_REG) continue;
            int nl = strlen(e->d_name), xl = strlen(SPEC_EXT);
            if (nl <= xl || strcmp(e->d_name + nl - xl, SPEC_EXT) != 0) continue;
            char buf[512];
            snprintf(buf, sizeof(buf), "%s/%s", SPEC_DIR, e->d_name);
            specs[nspecs++] = strdup(buf);
        }
        closedir(d);
        qsort(specs, nspecs, sizeof(char *), cmp_str);
    }

    /* collect executable linter impls */
    char *impls[MAX_IMPLS]; int nimpls = 0;
    {
        DIR *d = opendir(LINTER_DIR);
        struct dirent *e;
        while ((e = readdir(d)) && nimpls < MAX_IMPLS) {
            if (strncmp(e->d_name, LINTER_PFX, strlen(LINTER_PFX)) != 0) continue;
            char buf[512];
            snprintf(buf, sizeof(buf), "%s/%s", LINTER_DIR, e->d_name);
            if (access(buf, X_OK) != 0) continue;
            impls[nimpls++] = strdup(buf);
        }
        closedir(d);
        qsort(impls, nimpls, sizeof(char *), cmp_str);
    }

    if (nimpls == 0) {
        printf("no executable linters found in %s/\n", LINTER_DIR);
        return 1;
    }

    /* benchmark each */
    Result results[MAX_IMPLS];
    for (int i = 0; i < nimpls; i++)
        results[i] = bench_one(impls[i], specs, nspecs);

    qsort(results, nimpls, sizeof(Result), cmp_result_desc);

    /* find baseline: prefer awk, fallback sh, fallback fastest */
    double base_ips = results[0].ips_mean;
    const char *base_name = results[0].name;
    for (int i = 0; i < nimpls; i++) {
        if (strcmp(results[i].name, "awk") == 0) {
            base_ips = results[i].ips_mean; base_name = results[i].name; break;
        }
    }
    if (strcmp(base_name, "awk") != 0) {
        for (int i = 0; i < nimpls; i++) {
            if (strcmp(results[i].name, "sh") == 0) {
                base_ips = results[i].ips_mean; base_name = results[i].name; break;
            }
        }
    }

    printf("\n%-12s  %10s  %10s  %6s  %14s\n",
           "linter", "mean i/s", "min i/s", "cv%", "vs awk(mean)");
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
