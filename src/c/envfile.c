/* envfile.c - shared front-end for envfile implementations.
 *
 * The backend is selected at link time:
 *   - bin/envfile.c   links against src/c/backend.c
 *   - bin/envfile.asm links against src/c/backend.asm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "envfile_backend.h"

enum {
    READ_BUF = 4096,
    WORK_BUF = 65536
};

static const char *status_name(EnvfileStatus status) {
    switch (status) {
        case ENVFILE_ERR_NO_EQUALS:              return "ERROR_NO_EQUALS";
        case ENVFILE_ERR_EMPTY_KEY:              return "ERROR_EMPTY_KEY";
        case ENVFILE_ERR_KEY_INVALID:            return "ERROR_KEY_INVALID";
        case ENVFILE_ERR_KEY_LEADING_WHITESPACE: return "ERROR_KEY_LEADING_WHITESPACE";
        case ENVFILE_ERR_KEY_TRAILING_WHITESPACE:return "ERROR_KEY_TRAILING_WHITESPACE";
        case ENVFILE_ERR_VALUE_LEADING_WHITESPACE:return "ERROR_VALUE_LEADING_WHITESPACE";
        case ENVFILE_ERR_VALUE_INVALID_CHAR:     return "ERROR_VALUE_INVALID_CHAR";
        case ENVFILE_ERR_SINGLE_QUOTE_UNTERMINATED:
            return "ERROR_SINGLE_QUOTE_UNTERMINATED";
        case ENVFILE_ERR_DOUBLE_QUOTE_UNTERMINATED:
            return "ERROR_DOUBLE_QUOTE_UNTERMINATED";
        case ENVFILE_ERR_TRAILING_CONTENT:       return "ERROR_TRAILING_CONTENT";
        default:                                 return "ERROR_UNKNOWN";
    }
}

typedef struct {
    int checked;
    int errors;
} Counts;

static void emit_record(const EnvfileRecord *r) {
    fwrite(r->key, 1, r->key_len, stdout);
    fputc('=', stdout);
    fwrite(r->value, 1, r->value_len, stdout);
    fputc('\n', stdout);
}

static void report_error(EnvfileStatus status, const char *tag, size_t line_no) {
    fprintf(stderr, "%s: %s:%zu\n", status_name(status), tag, line_no);
}

static size_t find_last_newline(const unsigned char *buf, size_t len) {
    while (len > 0) {
        if (buf[len - 1] == '\n') return len - 1;
        len--;
    }
    return (size_t)-1;
}

static void scan_stream(
    FILE *f,
    const char *tag,
    EnvfileStatus (*parse)(const unsigned char *, size_t, EnvfileRecord *),
    int normalize,
    Counts *total
) {
    unsigned char read_buf[READ_BUF];
    unsigned char work_buf[WORK_BUF];
    size_t tail = 0;
    size_t line_no = 0;
    Counts counts = {0, 0};

    for (;;) {
        size_t nr = fread(read_buf, 1, sizeof read_buf, f);
        if (nr == 0 && ferror(f)) {
            fprintf(stderr, "envfile: read error: %s\n", tag);
            counts.errors++;
            break;
        }

        if (tail + nr > sizeof work_buf) {
            fprintf(stderr, "ERROR_LINE_TOO_LONG: %s\n", tag);
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
                    fprintf(stderr, "ERROR_LINE_TOO_LONG: %s\n", tag);
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
            EnvfileRecord record = {0};
            EnvfileStatus status;

            line_no++;
            status = parse(work_buf + pos, len, &record);
            if (status == ENVFILE_SKIP) {
                pos = nl ? end + 1 : limit;
                continue;
            }

            counts.checked++;
            if (status == ENVFILE_OK) {
                if (normalize) emit_record(&record);
            } else {
                report_error(status, tag, line_no);
                counts.errors++;
            }

            pos = nl ? end + 1 : limit;
        }

        if (eof) break;

        tail = filled - limit;
        if (tail > 0) memmove(work_buf, work_buf + limit, tail);
    }

    total->checked += counts.checked;
    total->errors += counts.errors;
}

int main(int argc, char *argv[]) {
    const char *format = getenv("ENVFILE_FORMAT");
    const char *action = getenv("ENVFILE_ACTION");
    if (!format) format = "strict";
    if (!action) action = "validate";

    int native = strcmp(format, "native") == 0;
    int normalize = strcmp(action, "normalize") == 0;

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

        scan_stream(
            f,
            path,
            native ? envfile_parse_native : envfile_parse_strict,
            normalize,
            &total
        );

        if (f != stdin) fclose(f);
    }

    fprintf(stderr, "%d checked, %d errors\n", total.checked, total.errors);
    return total.errors > 0 ? 1 : 0;
}
