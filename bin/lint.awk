#!/usr/bin/env -S awk -f
# awklint — validate env files (see README.md)

BEGIN {
    checked = 0; errors = 0; warnings = 0
    if (ARGC < 2) {
        printf "awklint: no files specified\n" > "/dev/stderr"
        exit 1
    }

    ERROR_NO_EQUALS              = "missing assignment (=)"
    ERROR_KEY_LEADING_WHITESPACE = "leading whitespace before key"
    ERROR_KEY_TRAILING_WHITESPACE = "whitespace before ="
    ERROR_VALUE_LEADING_WHITESPACE = "whitespace after ="
    ERROR_KEY_INVALID            = "invalid key '%s'"
    ERROR_DOUBLE_QUOTE_UNTERMINATED = "unterminated double quote"
    ERROR_SINGLE_QUOTE_UNTERMINATED = "unterminated single quote"
    ERROR_TRAILING_CONTENT       = "trailing content after closing quote"
    ERROR_VALUE_INVALID_CHAR     = "value contains whitespace, quote, or backslash"
    WARN_KEY_NOT_UPPERCASE       = "key '%s' is not UPPERCASE (preferred)"
}

{ sub(/\r$/, "") }  # strip carriage return for \r\n (Windows) line endings
/^[ \t]*$/ { next }
/^#/        { next }

{
    checked++

    if (!/=/) {
        printf "ERROR: (%s:%d) %s\n", FILENAME, NR, ERROR_NO_EQUALS > "/dev/stderr"
        errors++; next
    }

    eq = index($0, "=")
    k = substr($0, 1, eq - 1)
    v = substr($0, eq + 1)

    if (k ~ /^[ \t]/) {
        printf "ERROR: (%s:%d) %s\n", FILENAME, NR, ERROR_KEY_LEADING_WHITESPACE > "/dev/stderr"
        errors++; next
    }
    if (k ~ /[ \t]$/) {
        printf "ERROR: (%s:%d) %s\n", FILENAME, NR, ERROR_KEY_TRAILING_WHITESPACE > "/dev/stderr"
        errors++; next
    }
    if (v ~ /^[ \t]/) {
        printf "ERROR: (%s:%d) %s\n", FILENAME, NR, ERROR_VALUE_LEADING_WHITESPACE > "/dev/stderr"
        errors++; next
    }

    if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
        printf "ERROR: (%s:%d) " ERROR_KEY_INVALID "\n", FILENAME, NR, k > "/dev/stderr"
        errors++; next
    }

    if (k != toupper(k)) {
        printf "WARNING: (%s:%d) " WARN_KEY_NOT_UPPERCASE "\n", FILENAME, NR, k > "/dev/stderr"
        warnings++
    }

    len = length(v)
    if (len == 0) next

    c = substr(v, 1, 1)

    if (c == "\"") {
        rest = substr(v, 2)
        pos = index(rest, "\"")
        if (pos == 0) {
            printf "ERROR: (%s:%d) %s\n", FILENAME, NR, ERROR_DOUBLE_QUOTE_UNTERMINATED > "/dev/stderr"
            errors++; next
        }
        after = substr(rest, pos + 1)
        if (length(after) > 0) {
            printf "ERROR: (%s:%d) %s\n", FILENAME, NR, ERROR_TRAILING_CONTENT > "/dev/stderr"
            errors++; next
        }
    } else if (c == "'") {
        rest = substr(v, 2)
        pos = index(rest, "'")
        if (pos == 0) {
            printf "ERROR: (%s:%d) %s\n", FILENAME, NR, ERROR_SINGLE_QUOTE_UNTERMINATED > "/dev/stderr"
            errors++; next
        }
        after = substr(rest, pos + 1)
        if (length(after) > 0) {
            printf "ERROR: (%s:%d) %s\n", FILENAME, NR, ERROR_TRAILING_CONTENT > "/dev/stderr"
            errors++; next
        }
    } else {
        if (v ~ /[ \t'"\\]/) {
            printf "ERROR: (%s:%d) %s\n", FILENAME, NR, ERROR_VALUE_INVALID_CHAR > "/dev/stderr"
            errors++; next
        }
    }
}

END {
    printf "%d checked, %d errors, %d warnings\n", checked, errors, warnings > "/dev/stderr"
    if (errors) exit 1
}
