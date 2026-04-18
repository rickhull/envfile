#define _POSIX_C_SOURCE 200809L

/* nullscan.c — emit filenames whose contents contain no NUL bytes. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { BUF_SIZE = 1 << 16 };

static void note(const char *path, const char *msg) {
    fprintf(stderr, "nullscan: %s: %s\n", path, msg);
}

static int scan_stream(FILE *f, const char *path) {
    unsigned char buf[BUF_SIZE];

    for (;;) {
        size_t nr = fread(buf, 1, sizeof buf, f);
        if (nr > 0 && memchr(buf, 0, nr) != NULL) {
            note(path, "contains NUL byte");
            return 1;
        }
        if (nr < sizeof buf) {
            if (ferror(f)) {
                note(path, "read error");
                return 1;
            }
            break;
        }
    }

    puts(path);
    return 0;
}

static int scan_path(const char *path) {
    if (strcmp(path, "-") == 0) {
        return scan_stream(stdin, path);
    }

    FILE *f = fopen(path, "rb");
    if (!f) {
        note(path, "read error");
        return 1;
    }

    int rc = scan_stream(f, path);
    fclose(f);
    return rc;
}

static int scan_list(FILE *in) {
    char *line = NULL;
    size_t cap = 0;
    int failed = 0;
    ssize_t n;

    while ((n = getline(&line, &cap, in)) != -1) {
        while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) {
            line[--n] = '\0';
        }
        if (n == 0) continue;
        failed |= scan_path(line);
    }

    if (ferror(in)) {
        note("-", "read error");
        failed = 1;
    }

    free(line);
    return failed;
}

int main(int argc, char *argv[]) {
    int failed = 0;

    if (argc > 1) {
        for (int i = 1; i < argc; i++) {
            failed |= scan_path(argv[i]);
        }
    } else {
        failed = scan_list(stdin);
    }

    return failed ? 1 : 0;
}
