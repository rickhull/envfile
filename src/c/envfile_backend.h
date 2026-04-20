#ifndef ENVFILE_BACKEND_H
#define ENVFILE_BACKEND_H

#include <stddef.h>

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

typedef struct {
    const unsigned char *key;
    size_t               key_len;
    const unsigned char *value;      /* parsed: quotes stripped */
    size_t               value_len;
    const unsigned char *raw_value;  /* literal: as written in file */
    size_t               raw_value_len;
} EnvfileRecord;

EnvfileStatus envfile_parse_shell(
    const unsigned char *line, size_t len, EnvfileRecord *out
);

EnvfileStatus envfile_parse_native(
    const unsigned char *line, size_t len, EnvfileRecord *out
);

#endif
