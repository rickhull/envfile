/* envfile.c - shared front-end for envfile implementations.
 *
 * Reads ENVFILE_FORMAT, ENVFILE_ACTION, ENVFILE_BOM, ENVFILE_CRLF,
 * ENVFILE_NUL, and ENVFILE_BACKSLASH_CONTINUATION from the environment.
 * The backend is selected at link time:
 *   bin/envfile.c   links src/c/backend.c
 *   bin/envfile.asm links src/c/backend.asm
 * Both backends implement the same tiny record-classifier ABI declared in
 * src/c/envfile_backend.h, so the front-end never needs to know which one was
 * linked in.
 *
 * Pipeline: normalize → validate → dump → delta → apply
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "envfile_backend.h"

extern char **environ;

enum { READ_BUF = 4096, WORK_BUF = 65536 };

typedef enum {
    ACTION_NORMALIZE,
    ACTION_VALIDATE,
    ACTION_DUMP,
    ACTION_DELTA,
    ACTION_APPLY,
} Action;

typedef struct { int checked; int errors; } Counts;

typedef struct {
    char *key;
    size_t key_len;
    char *value;
} EnvPair;

typedef struct {
    EnvPair *pairs;
    size_t len;
    size_t cap;
} EnvTable;

typedef struct {
    char *buf;
    size_t len;
    size_t cap;
} StrBuf;

static Action parse_action(const char *s) {
    if (!s || strcmp(s, "validate") == 0) return ACTION_VALIDATE;
    if (strcmp(s, "normalize") == 0)      return ACTION_NORMALIZE;
    if (strcmp(s, "dump")      == 0)      return ACTION_DUMP;
    if (strcmp(s, "delta")     == 0)      return ACTION_DELTA;
    if (strcmp(s, "apply")     == 0)      return ACTION_APPLY;
    fprintf(stderr, "envfile: unsupported action: %s\n", s);
    exit(1);
}

static const char *status_name(EnvfileStatus s) {
    switch (s) {
        case ENVFILE_ERR_NO_EQUALS:                return "LINE_ERROR_NO_EQUALS";
        case ENVFILE_ERR_EMPTY_KEY:                return "LINE_ERROR_EMPTY_KEY";
        case ENVFILE_ERR_KEY_INVALID:              return "LINE_ERROR_KEY_INVALID";
        case ENVFILE_ERR_KEY_LEADING_WHITESPACE:   return "LINE_ERROR_KEY_LEADING_WHITESPACE";
        case ENVFILE_ERR_KEY_TRAILING_WHITESPACE:  return "LINE_ERROR_KEY_TRAILING_WHITESPACE";
        case ENVFILE_ERR_VALUE_LEADING_WHITESPACE: return "LINE_ERROR_VALUE_LEADING_WHITESPACE";
        case ENVFILE_ERR_VALUE_INVALID_CHAR:       return "LINE_ERROR_VALUE_INVALID_CHAR";
        case ENVFILE_ERR_SINGLE_QUOTE_UNTERMINATED:return "LINE_ERROR_SINGLE_QUOTE_UNTERMINATED";
        case ENVFILE_ERR_DOUBLE_QUOTE_UNTERMINATED:return "LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED";
        case ENVFILE_ERR_TRAILING_CONTENT:         return "LINE_ERROR_TRAILING_CONTENT";
        default:                                   return "LINE_ERROR_UNKNOWN";
    }
}

static int is_space_byte(unsigned char c) {
    return c == ' ' || c == '\t';
}

static int is_blank_or_comment_line(const unsigned char *line, size_t len) {
    if (len > 0 && line[len - 1] == '\r') len--;
    if (len == 0 || line[0] == '#') return 1;
    for (size_t i = 0; i < len; i++) {
        if (!is_space_byte(line[i])) return 0;
    }
    return 1;
}

static int all_records_have_trailing_cr(const unsigned char *buf, size_t len) {
    size_t pos = 0;
    if (len == 0) return 0;
    while (pos < len) {
        size_t end = pos;
        while (end < len && buf[end] != '\n') end++;
        size_t rlen = end - pos;
        if (rlen == 0 || buf[end - 1] != '\r') return 0;
        pos = (end < len) ? end + 1 : end;
    }
    return 1;
}

static char *xstrdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *copy = malloc(n);
    if (!copy) return NULL;
    memcpy(copy, s, n);
    return copy;
}

static char *xstrndup(const char *s, size_t n) {
    char *copy = malloc(n + 1);
    if (!copy) return NULL;
    memcpy(copy, s, n);
    copy[n] = '\0';
    return copy;
}

static void sb_init(StrBuf *b) {
    b->buf = NULL;
    b->len = 0;
    b->cap = 0;
}

static void sb_free(StrBuf *b) {
    free(b->buf);
    b->buf = NULL;
    b->len = 0;
    b->cap = 0;
}

static int sb_reserve(StrBuf *b, size_t extra) {
    size_t need = b->len + extra + 1;
    if (need <= b->cap) return 1;
    size_t cap = b->cap ? b->cap : 64;
    while (cap < need) cap *= 2;
    char *nb = realloc(b->buf, cap);
    if (!nb) return 0;
    b->buf = nb;
    b->cap = cap;
    return 1;
}

static int sb_append_n(StrBuf *b, const char *s, size_t n) {
    if (!sb_reserve(b, n)) return 0;
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = '\0';
    return 1;
}

static int sb_append(StrBuf *b, const char *s) {
    return sb_append_n(b, s, strlen(s));
}

static void env_table_free(EnvTable *env) {
    if (!env) return;
    for (size_t i = 0; i < env->len; i++) {
        free(env->pairs[i].key);
        free(env->pairs[i].value);
    }
    free(env->pairs);
    env->pairs = NULL;
    env->len = 0;
    env->cap = 0;
}

static int env_table_reserve(EnvTable *env, size_t extra) {
    size_t need = env->len + extra;
    if (need <= env->cap) return 1;
    size_t cap = env->cap ? env->cap : 32;
    while (cap < need) cap *= 2;
    EnvPair *np = realloc(env->pairs, cap * sizeof *np);
    if (!np) return 0;
    env->pairs = np;
    env->cap = cap;
    return 1;
}

static long env_table_find_n(const EnvTable *env, const char *key, size_t key_len) {
    for (size_t i = env->len; i > 0; i--) {
        const char *cur = env->pairs[i - 1].key;
        if (env->pairs[i - 1].key_len == key_len && memcmp(cur, key, key_len) == 0)
            return (long)(i - 1);
    }
    return -1;
}

static long env_table_find(const EnvTable *env, const char *key) {
    return env_table_find_n(env, key, strlen(key));
}

static const char *env_table_get(const EnvTable *env, const char *key) {
    long idx = env_table_find(env, key);
    return idx >= 0 ? env->pairs[idx].value : NULL;
}

static int env_table_set_n(EnvTable *env, const char *key, size_t key_len, const char *value) {
    long idx = env_table_find_n(env, key, key_len);
    if (idx >= 0) {
        char *copy = xstrdup(value);
        if (!copy) return 0;
        free(env->pairs[idx].value);
        env->pairs[idx].value = copy;
        return 1;
    }
    if (!env_table_reserve(env, 1)) return 0;
    env->pairs[env->len].key = malloc(key_len + 1);
    env->pairs[env->len].key_len = key_len;
    env->pairs[env->len].value = xstrdup(value);
    if (!env->pairs[env->len].key || !env->pairs[env->len].value) {
        free(env->pairs[env->len].key);
        free(env->pairs[env->len].value);
        return 0;
    }
    memcpy(env->pairs[env->len].key, key, key_len);
    env->pairs[env->len].key[key_len] = '\0';
    env->len++;
    return 1;
}

static int env_table_should_emit(const char *key) {
    return strncmp(key, "ENVFILE_", 8) != 0;
}

static int cmp_envpair_key(const void *a, const void *b) {
    const EnvPair *const *pa = a;
    const EnvPair *const *pb = b;
    return strcmp((*pa)->key, (*pb)->key);
}

static void env_table_emit_sorted(const EnvTable *env) {
    EnvPair **sorted = malloc(env->len * sizeof *sorted);
    if (!sorted) return;
    size_t n = 0;
    for (size_t i = 0; i < env->len; i++) {
        if (env_table_should_emit(env->pairs[i].key))
            sorted[n++] = (EnvPair *)&env->pairs[i];
    }
    qsort(sorted, n, sizeof *sorted, cmp_envpair_key);
    for (size_t i = 0; i < n; i++) {
        fputs(sorted[i]->key, stdout);
        fputc('=', stdout);
        fputs(sorted[i]->value, stdout);
        fputc('\n', stdout);
    }
    free(sorted);
}

static int env_table_init_from_process(EnvTable *env) {
    env->pairs = NULL;
    env->len = 0;
    env->cap = 0;
    for (char **ep = environ; ep && *ep; ep++) {
        const char *entry = *ep;
        const char *eq = strchr(entry, '=');
        if (!eq) continue;
        size_t key_len = (size_t)(eq - entry);
        if (key_len == 0 || (key_len >= 8 && strncmp(entry, "ENVFILE_", 8) == 0)) continue;
        if (!env_table_set_n(env, entry, key_len, eq + 1)) return 0;
    }
    return 1;
}

static int is_var_start(unsigned char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}

static int is_var_rest(unsigned char c) {
    return is_var_start(c) || (c >= '0' && c <= '9');
}

static char *subst_value(const char *val, const char *tag, size_t line_no, EnvTable *env, Counts *counts) {
    StrBuf out;
    sb_init(&out);

    while (*val) {
        const char *dollar = strchr(val, '$');
        if (!dollar) {
            if (!sb_append(&out, val)) goto oom;
            break;
        }
        if (!sb_append_n(&out, val, (size_t)(dollar - val))) goto oom;

        const char *rest = dollar + 1;
        if (*rest == '{') {
            const char *close = strchr(rest + 1, '}');
            if (!close) {
                if (!sb_append(&out, "$")) goto oom;
                if (!sb_append(&out, rest)) goto oom;
                break;
            }
            size_t name_len = (size_t)(close - (rest + 1));
            char *name = malloc(name_len + 1);
            if (!name) goto oom;
            memcpy(name, rest + 1, name_len);
            name[name_len] = '\0';
            const char *resolved = env_table_get(env, name);
            if (resolved) {
                if (!sb_append(&out, resolved)) {
                    free(name);
                    goto oom;
                }
            } else {
                fprintf(stderr, "LINE_ERROR_UNBOUND_REF (%s): %s:%zu\n", name, tag, line_no);
                counts->errors++;
            }
            free(name);
            val = close + 1;
            continue;
        }

        if (!is_var_start((unsigned char)*rest)) {
            if (!sb_append(&out, "$")) goto oom;
            val = rest;
            continue;
        }

        const char *p = rest + 1;
        while (*p && is_var_rest((unsigned char)*p)) p++;
        size_t name_len = (size_t)(p - rest);
        char *name = malloc(name_len + 1);
        if (!name) goto oom;
        memcpy(name, rest, name_len);
        name[name_len] = '\0';
        const char *resolved = env_table_get(env, name);
        if (resolved) {
            if (!sb_append(&out, resolved)) {
                free(name);
                goto oom;
            }
        } else {
            fprintf(stderr, "LINE_ERROR_UNBOUND_REF (%s): %s:%zu\n", name, tag, line_no);
            counts->errors++;
        }
        free(name);
        val = p;
    }

    return out.buf ? out.buf : xstrdup("");

oom:
    sb_free(&out);
    return NULL;
}

static void emit_record(const EnvfileRecord *r) {
    fwrite(r->key, 1, r->key_len, stdout);
    fputc('=', stdout);
    fwrite(r->value, 1, r->value_len, stdout);
    fputc('\n', stdout);
}

static size_t find_last_newline(const unsigned char *buf, size_t len) {
    while (len > 0) {
        if (buf[len - 1] == '\n') return len - 1;
        len--;
    }
    return (size_t)-1;
}

/* Count trailing backslashes on a line (for continuation detection). */
static int trailing_backslashes(const unsigned char *line, size_t len) {
    int n = 0;
    while (len > 0 && line[len - 1] == '\\') { n++; len--; }
    return n;
}

/* Normalize action: emit raw KEY=VALUE without key/value validation.
 * Matches AWK: skip blank/comment, error on no-equals, emit all others raw. */
static void normalize_stream(
    FILE *f,
    const char *tag,
    int strip_cr,
    int shell_cont,
    Counts *total
) {
    unsigned char read_buf[READ_BUF];
    unsigned char work_buf[WORK_BUF];
    /* join_buf holds a continuation-joined line being assembled */
    unsigned char join_buf[WORK_BUF];
    size_t join_len = 0;

    size_t tail = 0;
    size_t line_no = 0;
    Counts counts = {0, 0};

    for (;;) {
        size_t nr = fread(read_buf, 1, sizeof read_buf, f);
        if (nr == 0 && ferror(f)) {
            fprintf(stderr, "FILE_ERROR_FILE_UNREADABLE: %s\n", tag);
            counts.errors++;
            break;
        }

        if (tail + nr > sizeof work_buf) {
            fprintf(stderr, "LINE_ERROR_LINE_TOO_LONG: %s\n", tag);
            counts.errors++;
            break;
        }

        memcpy(work_buf + tail, read_buf, nr);
        size_t filled = tail + nr;
        int eof = (nr == 0);
        if (filled == 0) break;

        size_t limit;
        if (eof) {
            limit = filled;
        } else {
            size_t last_nl = find_last_newline(work_buf, filled);
            if (last_nl == (size_t)-1) {
                if (filled == sizeof work_buf) {
                    fprintf(stderr, "LINE_ERROR_LINE_TOO_LONG: %s\n", tag);
                    counts.errors++;
                    break;
                }
                tail = filled;
                continue;
            }
            limit = last_nl + 1;
        }

        size_t pos = 0;
        while (pos < limit) {
            const unsigned char *nl = memchr(work_buf + pos, '\n', limit - pos);
            size_t end = nl ? (size_t)(nl - work_buf) : limit;
            size_t len = end - pos;
            const unsigned char *line = work_buf + pos;

            line_no++;

            /* strip CRLF */
            if (strip_cr && len > 0 && line[len - 1] == '\r') len--;

            /* continuation joining (shell only) */
            if (shell_cont) {
                if (join_len + len > sizeof join_buf) {
                    fprintf(stderr, "LINE_ERROR_LINE_TOO_LONG: %s\n", tag);
                    counts.errors++;
                    join_len = 0;
                    pos = nl ? end + 1 : limit;
                    continue;
                }
                memcpy(join_buf + join_len, line, len);
                join_len += len;

                if (trailing_backslashes(join_buf, join_len) % 2 == 1 && nl) {
                    /* odd trailing backslashes: strip one '\' and join next line */
                    join_len--;
                    pos = nl ? end + 1 : limit;
                    continue;
                }
                line = join_buf;
                len  = join_len;
                join_len = 0;
            }

            if (is_blank_or_comment_line(line, len)) {
                pos = nl ? end + 1 : limit;
                continue;
            }

            counts.checked++;

            /* find first '=' */
            const unsigned char *eq = memchr(line, '=', len);
            if (!eq) {
                fprintf(stderr, "LINE_ERROR_NO_EQUALS: %s:%zu\n", tag, line_no);
                counts.errors++;
                pos = nl ? end + 1 : limit;
                continue;
            }

            /* emit raw KEY=VALUE */
            fwrite(line, 1, (size_t)(eq - line), stdout);
            fputc('=', stdout);
            size_t vlen = len - (size_t)(eq - line) - 1;
            fwrite(eq + 1, 1, vlen, stdout);
            fputc('\n', stdout);

            pos = nl ? end + 1 : limit;
        }

        if (eof) break;

        tail = filled - limit;
        if (tail > 0) memmove(work_buf, work_buf + limit, tail);
    }

    total->checked += counts.checked;
    total->errors  += counts.errors;
}

static void scan_stream(
    FILE *f,
    const char *tag,
    EnvfileStatus (*parse)(const unsigned char *, size_t, EnvfileRecord *),
    Action action,
    int strip_cr,
    int shell_cont,
    int native,
    EnvTable *env,
    Counts *total
) {
    unsigned char read_buf[READ_BUF];
    unsigned char work_buf[WORK_BUF];
    unsigned char join_buf[WORK_BUF];
    size_t join_len = 0;

    size_t tail = 0;
    size_t line_no = 0;
    Counts counts = {0, 0};

    for (;;) {
        size_t nr = fread(read_buf, 1, sizeof read_buf, f);
        if (nr == 0 && ferror(f)) {
            fprintf(stderr, "FILE_ERROR_FILE_UNREADABLE: %s\n", tag);
            counts.errors++;
            break;
        }

        if (tail + nr > sizeof work_buf) {
            fprintf(stderr, "LINE_ERROR_LINE_TOO_LONG: %s\n", tag);
            counts.errors++;
            break;
        }

        memcpy(work_buf + tail, read_buf, nr);
        size_t filled = tail + nr;
        int eof = (nr == 0);
        if (filled == 0) break;

        size_t limit;
        if (eof) {
            limit = filled;
        } else {
            size_t last_nl = find_last_newline(work_buf, filled);
            if (last_nl == (size_t)-1) {
                if (filled == sizeof work_buf) {
                    fprintf(stderr, "LINE_ERROR_LINE_TOO_LONG: %s\n", tag);
                    counts.errors++;
                    break;
                }
                tail = filled;
                continue;
            }
            limit = last_nl + 1;
        }

        size_t pos = 0;
        while (pos < limit) {
            const unsigned char *nl = memchr(work_buf + pos, '\n', limit - pos);
            size_t end = nl ? (size_t)(nl - work_buf) : limit;
            size_t len = end - pos;
            const unsigned char *line = work_buf + pos;

            line_no++;

            /* strip CRLF in the front-end */
            if (strip_cr && len > 0 && line[len - 1] == '\r') len--;

            /* continuation joining (shell only) */
            if (shell_cont) {
                if (join_len + len > sizeof join_buf) {
                    fprintf(stderr, "LINE_ERROR_LINE_TOO_LONG: %s\n", tag);
                    counts.errors++;
                    join_len = 0;
                    pos = nl ? end + 1 : limit;
                    continue;
                }
                memcpy(join_buf + join_len, line, len);
                join_len += len;

                if (trailing_backslashes(join_buf, join_len) % 2 == 1 && nl) {
                    join_len--;
                    pos = nl ? end + 1 : limit;
                    continue;
                }
                line = join_buf;
                len  = join_len;
                join_len = 0;
            }

            EnvfileRecord record = {0};
            EnvfileStatus status = parse(line, len, &record);

            if (status == ENVFILE_SKIP) {
                pos = nl ? end + 1 : limit;
                continue;
            }

            counts.checked++;
            if (status == ENVFILE_OK) {
                if (action == ACTION_DUMP) {
                    emit_record(&record);
                } else if (action == ACTION_DELTA || action == ACTION_APPLY) {
                    char *value = xstrndup((const char *)record.value, record.value_len);
                    char *resolved = NULL;
                    if (!value) {
                        fprintf(stderr, "envfile: out of memory: %s\n", tag);
                        counts.errors++;
                    } else if (native || record.value_kind != ENVFILE_VALUE_SINGLE_QUOTED) {
                        resolved = subst_value(value, tag, line_no, env, &counts);
                    } else {
                        resolved = value;
                        value = NULL;
                    }
                    if (!resolved) {
                        fprintf(stderr, "envfile: out of memory: %s\n", tag);
                        counts.errors++;
                    } else {
                        if (!env_table_set_n(env, (const char *)record.key, record.key_len, resolved)) {
                            free(resolved);
                            fprintf(stderr, "envfile: out of memory: %s\n", tag);
                            counts.errors++;
                            pos = nl ? end + 1 : limit;
                            continue;
                        }
                        if (action == ACTION_DELTA) {
                            fwrite(record.key, 1, record.key_len, stdout);
                            fputc('=', stdout);
                            fputs(resolved, stdout);
                            fputc('\n', stdout);
                        }
                        free(resolved);
                    }
                    free(value);
                }
            } else {
                fprintf(stderr, "%s: %s:%zu\n", status_name(status), tag, line_no);
                counts.errors++;
            }

            pos = nl ? end + 1 : limit;
        }

        if (eof) break;

        tail = filled - limit;
        if (tail > 0) memmove(work_buf, work_buf + limit, tail);
    }

    total->checked += counts.checked;
    total->errors  += counts.errors;
}

/* Returns 1 if the first three bytes of buf match the UTF-8 BOM. */
static int has_bom(const unsigned char *buf, size_t len) {
    return len >= 3 && buf[0] == 0xEF && buf[1] == 0xBB && buf[2] == 0xBF;
}

/* Process a single file: pre-passes (NUL, BOM) then line scanning. */
static void process_file(
    FILE *f,
    const char *tag,
    EnvfileStatus (*parse)(const unsigned char *, size_t, EnvfileRecord *),
    Action action,
    int strip_cr,
    int shell_cont,
    int native,
    const char *bom_mode,
    const char *nul_mode,
    EnvTable *env,
    Counts *total
) {
    /* Slurp the entire file for pre-passes. */
    unsigned char *fbuf = NULL;
    size_t flen = 0, fcap = 0;
    unsigned char tmp[READ_BUF];
    for (;;) {
        size_t nr = fread(tmp, 1, sizeof tmp, f);
        if (nr == 0) break;
        if (flen + nr > fcap) {
            fcap = (fcap == 0) ? 65536 : fcap * 2;
            if (flen + nr > fcap) fcap = flen + nr;
            unsigned char *nb = realloc(fbuf, fcap);
            if (!nb) {
                fprintf(stderr, "envfile: out of memory: %s\n", tag);
                free(fbuf);
                total->errors++;
                return;
            }
            fbuf = nb;
        }
        memcpy(fbuf + flen, tmp, nr);
        flen += nr;
    }
    if (ferror(f)) {
        fprintf(stderr, "FILE_ERROR_FILE_UNREADABLE: %s\n", tag);
        free(fbuf);
        total->errors++;
        return;
    }

    /* NUL pre-pass */
    if (!nul_mode || strcmp(nul_mode, "reject") == 0) {
        if (memchr(fbuf, '\0', flen)) {
            fprintf(stderr, "FILE_ERROR_NUL: %s\n", tag);
            free(fbuf);
            total->errors++;
            return;
        }
    }

    /* BOM pre-pass */
    size_t data_start = 0;
    if (has_bom(fbuf, flen)) {
        if (strcmp(bom_mode, "strip") == 0) {
            data_start = 3;
        } else if (strcmp(bom_mode, "reject") == 0) {
            fprintf(stderr, "FILE_ERROR_BOM: %s\n", tag);
            free(fbuf);
            total->errors++;
            return;
        }
    }

    if (strip_cr && !all_records_have_trailing_cr(fbuf + data_start, flen - data_start)) {
        strip_cr = 0;
    }

    /* Feed the (possibly BOM-stripped) data through a memory-backed FILE. */
    FILE *mf = fmemopen(fbuf + data_start, flen - data_start, "rb");
    if (!mf) {
        fprintf(stderr, "envfile: fmemopen failed: %s\n", tag);
        free(fbuf);
        total->errors++;
        return;
    }

    if (action == ACTION_NORMALIZE)
        normalize_stream(mf, tag, strip_cr, shell_cont, total);
    else
        scan_stream(mf, tag, parse, action, strip_cr, shell_cont, native, env, total);

    fclose(mf);
    free(fbuf);
}

int main(int argc, char *argv[]) {
    const char *format   = getenv("ENVFILE_FORMAT");
    const char *action_str = getenv("ENVFILE_ACTION");
    const char *bom_mode = getenv("ENVFILE_BOM");
    const char *crlf_mode = getenv("ENVFILE_CRLF");
    const char *nul_mode = getenv("ENVFILE_NUL");
    const char *cont_mode = getenv("ENVFILE_BACKSLASH_CONTINUATION");

    if (!format) format = "shell";

    int native = strcmp(format, "native") == 0;
    if (!bom_mode) bom_mode = native ? "literal" : "strip";
    if (strcmp(bom_mode, "literal") != 0 &&
        strcmp(bom_mode, "strip") != 0 &&
        strcmp(bom_mode, "reject") != 0) {
        fprintf(stderr, "FATAL_ERROR_BAD_ENVFILE_VALUE: ENVFILE_BOM=%s\n", bom_mode);
        return 1;
    }
    if (native && strcmp(bom_mode, "literal") != 0) {
        fprintf(stderr, "FATAL_ERROR_UNSUPPORTED: format=native ENVFILE_BOM=%s\n", bom_mode);
        return 1;
    }
    Action action = parse_action(action_str);

    /* CRLF: strip only when the whole file is CRLF-terminated */
    int strip_cr = crlf_mode && strcmp(crlf_mode, "strip") == 0;

    /* Continuation: shell only, default no */
    int shell_cont = !native && cont_mode && strcmp(cont_mode, "accept") == 0;

    EnvTable env = {0};
    if (action == ACTION_DELTA || action == ACTION_APPLY) {
        if (!env_table_init_from_process(&env)) {
            fprintf(stderr, "envfile: out of memory: %s\n", argv[0]);
            return 1;
        }
    }

    const char *defaults[] = { "-", NULL };
    const char **files = argc > 1 ? (const char **)argv + 1 : defaults;

    Counts total = {0, 0};
    for (int i = 0; files[i]; i++) {
        const char *path = files[i];
        FILE *f = strcmp(path, "-") == 0 ? stdin : fopen(path, "rb");
        if (!f) {
            fprintf(stderr, "envfile: cannot open: %s\n", path);
            total.errors++;
            continue;
        }
        process_file(
            f, path,
            native ? envfile_parse_native : envfile_parse_shell,
            action,
            strip_cr,
            shell_cont,
            native,
            bom_mode,
            nul_mode,
            &env,
            &total
        );
        if (f != stdin) fclose(f);
    }

    if (action == ACTION_APPLY)
        env_table_emit_sorted(&env);

    fprintf(stderr, "%d checked, %d errors\n", total.checked, total.errors);

    env_table_free(&env);

    return total.errors > 0 ? 1 : 0;
}
