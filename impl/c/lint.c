/* lint.c — validate env files (see README.md) */

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ERROR_NO_EQUALS                "missing assignment (=)"
#define ERROR_KEY_LEADING_WHITESPACE   "leading whitespace before key"
#define ERROR_KEY_TRAILING_WHITESPACE  "whitespace before ="
#define ERROR_VALUE_LEADING_WHITESPACE "whitespace after ="
#define ERROR_KEY_INVALID              "invalid key"
#define ERROR_DOUBLE_QUOTE_UNTERMINATED "unterminated double quote"
#define ERROR_SINGLE_QUOTE_UNTERMINATED "unterminated single quote"
#define ERROR_TRAILING_CONTENT         "trailing content after closing quote"
#define ERROR_VALUE_INVALID_CHAR       "value contains whitespace, quote, or backslash"
#define WARN_KEY_NOT_UPPERCASE         "is not UPPERCASE (preferred)"

typedef struct { int checked, errors, warnings; } Counts;

static int is_key_start(char c) { return isalpha((unsigned char)c) || c == '_'; }
static int is_key_rest(char c)  { return isalnum((unsigned char)c) || c == '_'; }
static int is_bad_val(char c)   { return isspace((unsigned char)c) || c == '\'' || c == '"' || c == '\\'; }

static Counts lint_file(const char *path) {
    Counts c = {0, 0, 0};
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "lint: %s: cannot open\n", path);
        c.errors++;
        return c;
    }

    char line[4096];
    int n = 0;

    while (fgets(line, sizeof(line), f)) {
        n++;
        /* strip trailing \n and \r */
        int len = (int)strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r'))
            line[--len] = '\0';

        /* skip blank lines */
        int all_space = 1;
        for (int i = 0; i < len; i++) if (!isspace((unsigned char)line[i])) { all_space = 0; break; }
        if (all_space) continue;

        /* skip comments */
        if (line[0] == '#') continue;
        c.checked++;

        char *eq = strchr(line, '=');
        if (!eq) {
            fprintf(stderr, "%s:%d: %s\n", path, n, ERROR_NO_EQUALS);
            c.errors++; continue;
        }

        *eq = '\0';
        char *k = line;
        char *v = eq + 1;
        int klen = (int)strlen(k);
        int vlen = (int)strlen(v);

        if (klen > 0 && isspace((unsigned char)k[0])) {
            fprintf(stderr, "%s:%d: %s\n", path, n, ERROR_KEY_LEADING_WHITESPACE);
            c.errors++; continue;
        }
        if (klen > 0 && isspace((unsigned char)k[klen-1])) {
            fprintf(stderr, "%s:%d: %s\n", path, n, ERROR_KEY_TRAILING_WHITESPACE);
            c.errors++; continue;
        }
        if (vlen > 0 && isspace((unsigned char)v[0])) {
            fprintf(stderr, "%s:%d: %s\n", path, n, ERROR_VALUE_LEADING_WHITESPACE);
            c.errors++; continue;
        }

        /* validate key */
        if (klen == 0 || !is_key_start(k[0])) {
            fprintf(stderr, "%s:%d: %s '%s'\n", path, n, ERROR_KEY_INVALID, k);
            c.errors++; continue;
        }
        int key_ok = 1;
        for (int i = 1; i < klen; i++) {
            if (!is_key_rest(k[i])) { key_ok = 0; break; }
        }
        if (!key_ok) {
            fprintf(stderr, "%s:%d: %s '%s'\n", path, n, ERROR_KEY_INVALID, k);
            c.errors++; continue;
        }

        /* warn if not uppercase */
        int all_upper = 1;
        for (int i = 0; i < klen; i++) {
            if (isalpha((unsigned char)k[i]) && !isupper((unsigned char)k[i])) { all_upper = 0; break; }
        }
        if (!all_upper) {
            fprintf(stderr, "%s:%d: key '%s' %s\n", path, n, k, WARN_KEY_NOT_UPPERCASE);
            c.warnings++;
        }

        if (vlen == 0) continue;

        char lead = v[0];
        if (lead == '"' || lead == '\'') {
            char *rest = v + 1;
            char *close = strchr(rest, lead);
            if (!close) {
                fprintf(stderr, "%s:%d: %s\n", path, n,
                    lead == '"' ? ERROR_DOUBLE_QUOTE_UNTERMINATED : ERROR_SINGLE_QUOTE_UNTERMINATED);
                c.errors++; continue;
            }
            if (*(close + 1) != '\0') {
                fprintf(stderr, "%s:%d: %s\n", path, n, ERROR_TRAILING_CONTENT);
                c.errors++; continue;
            }
        } else {
            for (int i = 0; i < vlen; i++) {
                if (is_bad_val(v[i])) {
                    fprintf(stderr, "%s:%d: %s\n", path, n, ERROR_VALUE_INVALID_CHAR);
                    c.errors++; break;
                }
            }
        }
    }

    fclose(f);
    return c;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "lint: no files specified\n");
        return 1;
    }

    Counts total = {0, 0, 0};
    for (int i = 1; i < argc; i++) {
        Counts c = lint_file(argv[i]);
        total.checked  += c.checked;
        total.errors   += c.errors;
        total.warnings += c.warnings;
    }

    fprintf(stderr, "%d checked, %d errors, %d warnings\n",
            total.checked, total.errors, total.warnings);

    return total.errors > 0 ? 1 : 0;
}
