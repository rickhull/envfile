/* backend.c - default C parser backend for envfile.
 *
 * This file is the C version of the record-classifier ABI declared in
 * src/c/envfile_backend.h.  The front-end in src/c/envfile.c owns file I/O,
 * normalization, substitution, and action handling; this backend only decides
 * whether one already-delimited line is a shell/native record and, if so,
 * fills EnvfileRecord.
 */

#include <string.h>

#include "envfile_backend.h"

static int is_ascii_upper(unsigned char c) { return c >= 'A' && c <= 'Z'; }
static int is_ascii_lower(unsigned char c) { return c >= 'a' && c <= 'z'; }
static int is_ascii_alpha(unsigned char c) { return is_ascii_upper(c) || is_ascii_lower(c); }
static int is_ascii_digit(unsigned char c) { return c >= '0' && c <= '9'; }
static int is_ascii_alnum(unsigned char c) { return is_ascii_alpha(c) || is_ascii_digit(c); }
static int is_space_byte(unsigned char c) { return c == ' ' || c == '\t'; }

static int is_blank_or_comment_record(const unsigned char *s, size_t len) {
    if (len > 0 && s[len - 1] == '\r') len--;
    if (len == 0 || s[0] == '#') return 1;
    for (size_t i = 0; i < len; i++) {
        if (!is_space_byte(s[i])) return 0;
    }
    return 1;
}

static int is_shell_key_start(unsigned char c) { return is_ascii_alpha(c) || c == '_'; }
static int is_shell_key_rest(unsigned char c) { return is_ascii_alnum(c) || c == '_'; }

static void fill_record(
    EnvfileRecord *out,
    const unsigned char *line,
    size_t key_len,
    const unsigned char *value,
    size_t value_len,
    EnvfileValueKind value_kind
) {
    out->key        = line;
    out->key_len    = key_len;
    out->value      = value;
    out->value_len  = value_len;
    out->value_kind = value_kind;
}

static EnvfileStatus parse_shell(
    const unsigned char *line,
    size_t len,
    EnvfileRecord *out
) {
    if (is_blank_or_comment_record(line, len)) return ENVFILE_SKIP;
    if (memchr(line, '\0', len)) return ENVFILE_ERR_VALUE_INVALID_CHAR;

    const unsigned char *eq = memchr(line, '=', len);
    if (!eq) return ENVFILE_ERR_NO_EQUALS;

    size_t key_len = (size_t)(eq - line);
    if (key_len == 0) return ENVFILE_ERR_EMPTY_KEY;
    if (is_space_byte(line[0])) return ENVFILE_ERR_KEY_LEADING_WHITESPACE;
    if (is_space_byte(line[key_len - 1])) return ENVFILE_ERR_KEY_TRAILING_WHITESPACE;
    if (!is_shell_key_start(line[0])) return ENVFILE_ERR_KEY_INVALID;
    for (size_t i = 1; i < key_len; i++) {
        if (!is_shell_key_rest(line[i])) return ENVFILE_ERR_KEY_INVALID;
    }

    const unsigned char *value = eq + 1;
    size_t value_len = len - key_len - 1;

    if (value_len > 0 && is_space_byte(value[0]))
        return ENVFILE_ERR_VALUE_LEADING_WHITESPACE;

    if (value_len > 0 && (value[0] == '"' || value[0] == '\'')) {
        unsigned char quote = value[0];
        const unsigned char *rest = value + 1;
        size_t rest_len = value_len - 1;
        const unsigned char *close = memchr(rest, quote, rest_len);
        if (!close)
            return quote == '"' ? ENVFILE_ERR_DOUBLE_QUOTE_UNTERMINATED
                                : ENVFILE_ERR_SINGLE_QUOTE_UNTERMINATED;
        if (close + 1 != line + len) return ENVFILE_ERR_TRAILING_CONTENT;
        value     = rest;
        value_len = (size_t)(close - rest);
        fill_record(out, line, key_len, value, value_len,
                    quote == '\'' ? ENVFILE_VALUE_SINGLE_QUOTED
                                  : ENVFILE_VALUE_DOUBLE_QUOTED);
        return ENVFILE_OK;
    } else {
        for (size_t i = 0; i < value_len; i++) {
            if (is_space_byte(value[i]) ||
                value[i] == '\'' || value[i] == '"' || value[i] == '\\')
                return ENVFILE_ERR_VALUE_INVALID_CHAR;
        }
    }

    fill_record(out, line, key_len, value, value_len, ENVFILE_VALUE_PLAIN);
    return ENVFILE_OK;
}

static EnvfileStatus parse_native(
    const unsigned char *line,
    size_t len,
    EnvfileRecord *out
) {
    if (is_blank_or_comment_record(line, len)) return ENVFILE_SKIP;
    if (memchr(line, '\0', len)) return ENVFILE_ERR_VALUE_INVALID_CHAR;

    const unsigned char *eq = memchr(line, '=', len);
    if (!eq) return ENVFILE_ERR_NO_EQUALS;

    size_t key_len = (size_t)(eq - line);
    if (key_len == 0) return ENVFILE_ERR_EMPTY_KEY;

    const unsigned char *value = eq + 1;
    size_t value_len = len - key_len - 1;
    fill_record(out, line, key_len, value, value_len, ENVFILE_VALUE_PLAIN);
    return ENVFILE_OK;
}

EnvfileStatus envfile_parse_shell(
    const unsigned char *line, size_t len, EnvfileRecord *out
) {
    return parse_shell(line, len, out);
}

EnvfileStatus envfile_parse_native(
    const unsigned char *line, size_t len, EnvfileRecord *out
) {
    return parse_native(line, len, out);
}
