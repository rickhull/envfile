#!/usr/bin/env -S awk -f
# nullscan.awk — filter filenames whose files contain no NUL bytes.

function note(path, msg) {
    printf "nullscan: %s: %s\n", path, msg > "/dev/stderr"
}

function scan(path,    line, nul, saw_nul, rc) {
    if (path == "-") path = "/dev/stdin"
    nul = sprintf("%c", 0)
    saw_nul = 0

    while ((getline line < path) > 0) {
        if (index(line, nul) > 0) {
            saw_nul = 1
            break
        }
    }

    rc = close(path)
    if (rc != 0 && rc != 1) {
        note(path, "read error")
        return 1
    }
    if (saw_nul) {
        note(path, "contains NUL byte")
        return 1
    }

    print path
    return 0
}

BEGIN {
    failed = 0
    had_arg = (ARGC > 1)

    if (had_arg) {
        for (i = 1; i < ARGC; i++) {
            path = ARGV[i]
            if (path == "") continue
            if (scan(path)) failed = 1
        }
        exit failed
    }

    while ((getline path) > 0) {
        if (path == "") continue
        if (scan(path)) failed = 1
    }
    exit failed
}
