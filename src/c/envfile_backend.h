#ifndef ENVFILE_BACKEND_H
#define ENVFILE_BACKEND_H

#include <stddef.h>

/* The front-end owns file I/O, normalization, environment handling, and
 * actions.  The backend only classifies one already-delimited record at a time.
 * C and ASM both implement the same ABI so the backend can be swapped at link
 * time without changing the front-end.
 */

typedef enum {
    ENVFILE_VALUE_PLAIN = 0,
    ENVFILE_VALUE_SINGLE_QUOTED = 1,
    ENVFILE_VALUE_DOUBLE_QUOTED = 2,
} EnvfileValueKind;

typedef enum {
    ENVFILE_SKIP = 0,
    ENVFILE_OK = 1,
    ENVFILE_ERR_NO_EQUALS = 10,
    ENVFILE_ERR_EMPTY_KEY = 11,
    ENVFILE_ERR_KEY_INVALID = 12,
    ENVFILE_ERR_KEY_LEADING_WHITESPACE = 13,
    ENVFILE_ERR_KEY_TRAILING_WHITESPACE = 14,
    ENVFILE_ERR_VALUE_LEADING_WHITESPACE = 15,
    ENVFILE_ERR_VALUE_INVALID_CHAR = 16,
    ENVFILE_ERR_SINGLE_QUOTE_UNTERMINATED = 17,
    ENVFILE_ERR_DOUBLE_QUOTE_UNTERMINATED = 18,
    ENVFILE_ERR_TRAILING_CONTENT = 19,
} EnvfileStatus;

/* Record layout shared by C and ASM:
 *   key points at the original line buffer
 *   value points at the parsed payload
 *   value_len excludes wrapping quotes for shell records
 *   value_kind tells the front-end whether shell substitution is allowed
 */
typedef struct {
    const unsigned char *key;
    size_t               key_len;
    const unsigned char *value;      /* parsed payload */
    size_t               value_len;
    EnvfileValueKind     value_kind;
} EnvfileRecord;

EnvfileStatus envfile_parse_shell(
    const unsigned char *line, size_t len, EnvfileRecord *out
);

EnvfileStatus envfile_parse_native(
    const unsigned char *line, size_t len, EnvfileRecord *out
);

#endif
