#!/usr/bin/env -S awk -f
# nullscan.awk — filter filenames whose files contain no NUL bytes.
# Bootstrap only: awk's getline splits on NUL, so detection is not fully
# reliable for files with NUL mid-line. The C binary (bin/nullscan) is
# authoritative; this script is used when the C binary is not yet built.

BEGIN {
    _NUL = sprintf("%c", 0)
    failed = 0

    if (ARGC > 1) {
        for (i = 1; i < ARGC; i++) {
            if (ARGV[i] != "") if (scan(ARGV[i])) failed = 1
        }
    } else {
        while ((getline path) > 0)
            if (path != "") { if (scan(path)) failed = 1 }
    }
    exit failed
}

function scan(path,    line, rc) {
    if (path == "-") path = "/dev/stdin"

    while ((getline line < path) > 0) {
        if (index(line, _NUL) > 0) {
            close(path)
            note(path, "contains NUL byte")
            return 1
        }
    }

    rc = close(path)
    if (rc != 0 && rc != 1) { note(path, "read error"); return 1 }

    print path
    return 0
}

function note(path, msg) {
    printf "nullscan: %s: %s\n", path, msg > "/dev/stderr"
}
