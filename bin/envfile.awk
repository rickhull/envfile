#!/usr/bin/env -S LC_ALL=C awk -f
# envfile.awk — reference implementation; all config via ENVFILE_* env vars
#
# ENVFILE_FORMAT                shell|native|compat              (default: shell)
# ENVFILE_ACTION                normalize|validate|dump|delta|apply  (default: validate)
# ENVFILE_BOM                   reject|warn|strip                (default: warn)
# ENVFILE_CRLF                  strip|ignore                     (default: ignore)
# ENVFILE_NUL                   reject|ignore                    (default: reject)
# ENVFILE_BACKSLASH_CONTINUATION accept|ignore                   (default: ignore)
#
# Pipeline: normalize → validate → dump → delta → apply
# Each action runs all prior stages implicitly.

BEGIN {
    format = ENVIRON["ENVFILE_FORMAT"]       != "" ? ENVIRON["ENVFILE_FORMAT"]       : "shell"
    action = ENVIRON["ENVFILE_ACTION"]       != "" ? ENVIRON["ENVFILE_ACTION"]       : "validate"
    bom    = ENVIRON["ENVFILE_BOM"]                   != "" ? ENVIRON["ENVFILE_BOM"]                   : "warn"
    crlf   = ENVIRON["ENVFILE_CRLF"]                  != "" ? ENVIRON["ENVFILE_CRLF"]                  : "ignore"
    nul    = ENVIRON["ENVFILE_NUL"]                   != "" ? ENVIRON["ENVFILE_NUL"]                   : "reject"
    cont   = ENVIRON["ENVFILE_BACKSLASH_CONTINUATION"] != "" ? ENVIRON["ENVFILE_BACKSLASH_CONTINUATION"] : "ignore"

    NUL = sprintf("%c", 0)
    BOM = sprintf("%c%c%c", 0xef, 0xbb, 0xbf)

    for (i = 1; i < ARGC; i++)
        if (ARGV[i] == "-") ARGV[i] = "/dev/stdin"

    if (action == "delta" || action == "apply")
        for (k in ENVIRON)
            if (substr(k, 1, 8) != "ENVFILE_")
                env[k] = ENVIRON[k]

    for (i = 1; i < ARGC; i++) {
        if (ARGV[i] == "") continue
        normalize(ARGV[i])
        ARGV[i] = ""
    }

    if (action == "apply")
        emit_env_sorted()

    printf "%d checked, %d errors\n", checked, errors > "/dev/stderr"
    exit (errors ? 1 : 0)
}

# normalize: slurp file; apply pre-passes; feed canonical lines into validate()
function normalize(path,    rc, raw, lines, n, i, line, all_crlf) {
    n = 0
    while ((rc = (getline raw < path)) > 0) {
        if (nul == "reject" && index(raw, NUL) > 0) {
            printf "FILE_ERROR_NUL: %s\n", path > "/dev/stderr"
            errors++; close(path); return
        }
        lines[++n] = raw
    }
    close(path)
    if (rc < 0) {
        printf "FILE_ERROR_FILE_UNREADABLE: %s\n", path > "/dev/stderr"
        errors++; return
    }

    if (n > 0 && index(lines[1], BOM) == 1) {
        if (bom == "reject") {
            printf "FILE_ERROR_BOM: %s\n", path > "/dev/stderr"
            errors++; return
        }
        if (bom == "warn") printf "WARNING_BOM: %s\n", path > "/dev/stderr"
        lines[1] = substr(lines[1], 4)
    }

    if (crlf == "strip") {
        all_crlf = 1
        for (i = 1; i <= n; i++)
            if (substr(lines[i], length(lines[i]), 1) != "\r") { all_crlf = 0; break }
        if (all_crlf)
            for (i = 1; i <= n; i++)
                lines[i] = substr(lines[i], 1, length(lines[i]) - 1)
    }

    i = 1
    while (i <= n) {
        line = lines[i++]
        if (cont == "accept")
            while (is_continuation(line) && i <= n)
                line = substr(line, 1, length(line) - 1) lines[i++]
        validate(line, path, i - 1)
    }
}

# a line ending in an odd number of backslashes continues onto the next line
function is_continuation(line,    j, n) {
    j = length(line); n = 0
    while (j > 0 && substr(line, j--, 1) == "\\") n++
    return n % 2 == 1
}

# validate: check format-specific key/value rules; feed accepted records into dump()
function validate(line, path, lineno,    eq, k, v, trimmed) {
    trimmed = line; sub(/\r$/, "", trimmed)
    if (trimmed ~ /^[ \t]*$/ || trimmed ~ /^#/) return

    checked++
    eq = index(line, "=")

    if (format == "native") {
        if (eq == 0)                    { diag("LINE_ERROR_NO_EQUALS",   path, lineno); return }
        k = substr(line, 1, eq - 1)
        v = substr(line, eq + 1)
        if (action == "normalize")      { print k "=" v; return }
        # native only requires a non-empty name; the rest is literal data
        if (k == "")                    { diag("LINE_ERROR_EMPTY_KEY",   path, lineno); return }
        dump(k, v, v, path, lineno)
        return
    }

    # shell / compat
    if (eq == 0)                          { diag("LINE_ERROR_NO_EQUALS",                path, lineno); return }
    k = substr(line, 1, eq - 1)
    v = substr(line, eq + 1)
    if (action == "normalize")            { print k "=" v; return }
    if (k == "")                          { diag("LINE_ERROR_EMPTY_KEY",                path, lineno); return }
    if (k ~ /^[ \t]/)                     { diag("LINE_ERROR_KEY_LEADING_WHITESPACE",   path, lineno); return }
    if (k ~ /[ \t]$/)                     { diag("LINE_ERROR_KEY_TRAILING_WHITESPACE",  path, lineno); return }
    if (v ~ /^[ \t]/)                     { diag("LINE_ERROR_VALUE_LEADING_WHITESPACE", path, lineno); return }
    if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { diag("LINE_ERROR_KEY_INVALID",              path, lineno); return }
    dump(k, v, unquote(v, path, lineno), path, lineno)
}

# unquote: strip quote wrapper; return bare value, or sentinel "\001" on error
function unquote(v, path, lineno,    c, rest, pos) {
    if (length(v) == 0) return v
    c = substr(v, 1, 1)
    if (c == "\"" || c == "'") {
        rest = substr(v, 2)
        pos  = index(rest, c)
        if (pos == 0) {
            diag(c == "\"" ? "LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED" : "LINE_ERROR_SINGLE_QUOTE_UNTERMINATED", path, lineno)
            return "\001"
        }
        if (pos < length(rest)) { diag("LINE_ERROR_TRAILING_CONTENT", path, lineno); return "\001" }
        return substr(rest, 1, pos - 1)
    }
    if (v ~ /[ \t'"\\]/) { diag("LINE_ERROR_VALUE_INVALID_CHAR", path, lineno); return "\001" }
    return v
}

# dump: emit parsed value; chain to delta() for later actions
function dump(k, raw, value, path, lineno) {
    if (value == "\001") return
    if (action == "dump") { print k "=" value; return }
    delta(k, raw, value, path, lineno)
}

# delta: resolve $VAR/${VAR} references; accumulate bindings for apply
function delta(k, raw, value, path, lineno) {
    if (action == "validate") return
    # single-quoted shell values are fully literal; everything else substitutes
    if (format == "native" || substr(raw, 1, 1) != "'")
        value = subst(value, path, lineno)
    env[k] = value
    if (action == "delta") print k "=" value
}

function emit_env_sorted(    keys, n, k, i, j, tmp) {
    n = 0
    for (k in env)
        if (substr(k, 1, 8) != "ENVFILE_")
            keys[++n] = k
    for (i = 1; i <= n; i++) {
        for (j = i + 1; j <= n; j++) {
            if (keys[j] < keys[i]) {
                tmp = keys[i]
                keys[i] = keys[j]
                keys[j] = tmp
            }
        }
    }
    for (i = 1; i <= n; i++)
        print keys[i] "=" env[keys[i]]
}

# subst: walk value resolving $VAR and ${VAR} against env[]
function subst(val, path, lineno,    out, rest, brace, name, pos) {
    out = ""
    while (length(val) > 0) {
        pos = index(val, "$")
        if (pos == 0) { out = out val; break }
        out  = out substr(val, 1, pos - 1)
        rest = substr(val, pos + 1)
        if (substr(rest, 1, 1) == "{") {
            brace = index(substr(rest, 2), "}")
            if (brace == 0) { out = out "$" rest; break }
            name = substr(rest, 2, brace - 1)
            val  = substr(rest, brace + 2)
        } else {
            match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)
            if (RLENGTH < 1) { out = out "$"; val = rest; continue }
            name = substr(rest, 1, RLENGTH)
            val  = substr(rest, RLENGTH + 1)
        }
        if (name in env) out = out env[name]
        else { printf "LINE_ERROR_UNBOUND_REF (%s): %s:%d\n", name, path, lineno > "/dev/stderr"; errors++ }
    }
    return out
}

function diag(code, path, lineno) {
    printf "%s: %s:%d\n", code, path, lineno > "/dev/stderr"
    errors++
}
