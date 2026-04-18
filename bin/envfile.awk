#!/usr/bin/env -S awk -f
# envfile.awk — validate env files (see README.md)

BEGIN {
    checked = errors = 0
    mode   = (ENVIRON["ENVFILE_FORMAT"] != "") ? ENVIRON["ENVFILE_FORMAT"] : "strict"
    action = (ENVIRON["ENVFILE_ACTION"] != "") ? ENVIRON["ENVFILE_ACTION"] : "validate"
    nul = sprintf("%c", 0)

    for (i = 1; i < ARGC; i++)
        if (ARGV[i] == "-") ARGV[i] = "/dev/stdin"
}

function diag(code) {
    printf "%s: %s:%d\n", code, FILENAME, FNR > "/dev/stderr"
    errors++
}

mode != "native" { sub(/\r$/, "") }

index($0, nul) > 0 { checked++; diag("ERROR_VALUE_INVALID_CHAR"); next }
/^[ \t]*$/ || /^#/ { next }

{
    checked++
    eq = index($0, "=")

    if (mode == "native") {
        if (eq == 0)          { diag("ERROR_NO_EQUALS");  next }
        k = substr($0, 1, eq - 1)
        v = substr($0, eq + 1)
        if (k == "")          { diag("ERROR_EMPTY_KEY");  next }
        if (k !~ /^[A-Z_][A-Z0-9_]*$/) { diag("ERROR_KEY_INVALID"); next }
        if (action == "normalize") print k "=" v
        next
    }

    if (eq == 0)              { diag("ERROR_NO_EQUALS");  next }
    k = substr($0, 1, eq - 1)
    v = substr($0, eq + 1)

    if (k ~ /^[ \t]/)        { diag("ERROR_KEY_LEADING_WHITESPACE");   next }
    if (k ~ /[ \t]$/)        { diag("ERROR_KEY_TRAILING_WHITESPACE");  next }
    if (v ~ /^[ \t]/)        { diag("ERROR_VALUE_LEADING_WHITESPACE"); next }
    if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { diag("ERROR_KEY_INVALID"); next }

    value = v
    if (length(v) > 0) {
        c = substr(v, 1, 1)
        if (c == "\"" || c == "'") {
            rest = substr(v, 2)
            pos  = index(rest, c)
            if (pos == 0) {
                diag(c == "\"" ? "ERROR_DOUBLE_QUOTE_UNTERMINATED" : "ERROR_SINGLE_QUOTE_UNTERMINATED")
                next
            }
            if (length(substr(rest, pos + 1)) > 0) { diag("ERROR_TRAILING_CONTENT"); next }
            value = substr(rest, 1, pos - 1)
        } else if (v ~ /[ \t'"\\]/) {
            diag("ERROR_VALUE_INVALID_CHAR"); next
        }
    }

    if (action == "normalize") print k "=" value
}

END {
    printf "%d checked, %d errors\n", checked, errors > "/dev/stderr"
    if (errors) exit 1
}
