#!/usr/bin/env python3
"""envfile.py — validate/normalize env files (see README.md)"""

import os
import re
import sys

KEY_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')
BAD_VAL_RE = re.compile(r"""[\s'"\\]""")

ERROR_NO_EQUALS = "ERROR_NO_EQUALS"
ERROR_EMPTY_KEY = "ERROR_EMPTY_KEY"
ERROR_KEY_LEADING_WHITESPACE = "ERROR_KEY_LEADING_WHITESPACE"
ERROR_KEY_TRAILING_WHITESPACE = "ERROR_KEY_TRAILING_WHITESPACE"
ERROR_VALUE_LEADING_WHITESPACE = "ERROR_VALUE_LEADING_WHITESPACE"
ERROR_KEY_INVALID = "ERROR_KEY_INVALID"
ERROR_DOUBLE_QUOTE_UNTERMINATED = "ERROR_DOUBLE_QUOTE_UNTERMINATED"
ERROR_SINGLE_QUOTE_UNTERMINATED = "ERROR_SINGLE_QUOTE_UNTERMINATED"
ERROR_TRAILING_CONTENT = "ERROR_TRAILING_CONTENT"
ERROR_VALUE_INVALID_CHAR = "ERROR_VALUE_INVALID_CHAR"

FORMAT = os.environ.get("ENVFILE_FORMAT", "shell")
ACTION = os.environ.get("ENVFILE_ACTION", "validate")

EQ = ord('=')
NL = ord('\n')
HASH = ord('#')
UNDER = ord('_')


def _emit(norm, key, value):
    norm.extend(key)
    norm.extend(b"=")
    norm.extend(value)
    norm.extend(b"\n")


def _valid_native_key(key):
    if not key:
        return False
    b = key[0]
    if not (ord('A') <= b <= ord('Z') or b == UNDER):
        return False
    for b in key[1:]:
        if not (ord('A') <= b <= ord('Z') or ord('0') <= b <= ord('9') or b == UNDER):
            return False
    return True


def _native_record(line, tag, n, diag, norm, normalize):
    if b"\x00" in line:
        diag.extend(f"{ERROR_VALUE_INVALID_CHAR}: {tag}:{n}\n".encode())
        return 1, 1
    if not line or not line.strip() or line[0] == HASH:
        return 0, 0
    eq = line.find(EQ)
    if eq == -1:
        diag.extend(f"{ERROR_NO_EQUALS}: {tag}:{n}\n".encode())
        return 1, 1
    k, v = line[:eq], line[eq + 1:]
    if not k:
        diag.extend(f"{ERROR_EMPTY_KEY}: {tag}:{n}\n".encode())
        return 1, 1
    if not _valid_native_key(k):
        diag.extend(f"{ERROR_KEY_INVALID}: {tag}:{n}\n".encode())
        return 1, 1
    if normalize:
        _emit(norm, k, v)
    return 1, 0


def native_scan(buf, tag, diag, norm, normalize):
    checked = errors = 0
    n = pos = 0
    while pos <= len(buf):
        nl = buf.find(NL, pos)
        end = nl if nl != -1 else len(buf)
        if end > pos or nl != -1:
            n += 1
            line = buf[pos:end]
            if b"\x00" in line:
                diag.extend(f"{ERROR_VALUE_INVALID_CHAR}: {tag}:{n}\n".encode())
                checked += 1
                errors += 1
            elif not line or not line.strip() or line[0] == HASH:
                pass
            else:
                c, e = _native_record(line, tag, n, diag, norm, normalize)
                checked += c
                errors += e
        if nl == -1:
            break
        pos = nl + 1
    return checked, errors


def _open_file(path):
    if path == "-":
        return sys.stdin
    return open(path, "r")


def _shell_line(f, n, k, v, error, out, normalize):
    if k != k.lstrip():
        error(n, ERROR_KEY_LEADING_WHITESPACE); return
    if k != k.rstrip():
        error(n, ERROR_KEY_TRAILING_WHITESPACE); return
    if v and v != v.lstrip():
        error(n, ERROR_VALUE_LEADING_WHITESPACE); return
    if not k:
        error(n, ERROR_EMPTY_KEY); return
    if not KEY_RE.match(k):
        error(n, ERROR_KEY_INVALID); return

    if v:
        c = v[0]
        if c == '"':
            rest = v[1:]
            pos = rest.find('"')
            if pos == -1:
                error(n, ERROR_DOUBLE_QUOTE_UNTERMINATED); return
            if rest[pos + 1:]:
                error(n, ERROR_TRAILING_CONTENT); return
            v = rest[:pos]
        elif c == "'":
            rest = v[1:]
            pos = rest.find("'")
            if pos == -1:
                error(n, ERROR_SINGLE_QUOTE_UNTERMINATED); return
            if rest[pos + 1:]:
                error(n, ERROR_TRAILING_CONTENT); return
            v = rest[:pos]
        else:
            if BAD_VAL_RE.search(v):
                error(n, ERROR_VALUE_INVALID_CHAR); return

    if normalize:
        print(f"{k}={v}", file=out)


def _lint_file(f, out, normalize):
    if FORMAT == "native":
        if f == "-":
            buf = sys.stdin.buffer.read()
        else:
            with open(f, "rb") as fh:
                buf = fh.read()
        diag = bytearray()
        norm = bytearray()
        checked, errors = native_scan(buf, f, diag, norm, normalize)
        if norm:
            sys.stdout.buffer.write(norm)
        out.buffer.write(diag)
        return checked, errors

    checked = errors = 0

    def error(n, msg):
        nonlocal errors
        print(f"{msg}: {f}:{n}", file=out)
        errors += 1

    with _open_file(f) as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if line.endswith("\r"):
                line = line[:-1]
            if "\x00" in line:
                error(n, ERROR_VALUE_INVALID_CHAR)
                continue
            if not line.strip():
                continue
            if line.startswith("#"):
                continue
            checked += 1
            if "=" not in line:
                error(n, ERROR_NO_EQUALS)
                continue
            k, v = line.split("=", 1)
            _shell_line(f, n, k, v, error, out, normalize)

    return checked, errors


def lint(files, out=sys.stderr):
    normalize = ACTION == "normalize"
    total_checked = total_errors = 0
    if not files:
        files = ["-"]
    for f in files:
        c, e = _lint_file(f, out, normalize)
        total_checked += c
        total_errors += e
    print(f"{total_checked} checked, {total_errors} errors", file=out)
    return total_errors


if __name__ == "__main__":
    sys.exit(1 if lint(sys.argv[1:]) > 0 else 0)
