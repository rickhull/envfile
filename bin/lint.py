#!/usr/bin/env python3
"""lint.py — validate env files (see README.md)"""

import re
import sys

KEY_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')
BAD_VAL_RE = re.compile(r"""[\s'"\\]""")

ERROR_NO_EQUALS                = "missing assignment (=)"
ERROR_KEY_LEADING_WHITESPACE   = "leading whitespace before key"
ERROR_KEY_TRAILING_WHITESPACE  = "whitespace before ="
ERROR_VALUE_LEADING_WHITESPACE = "whitespace after ="
ERROR_KEY_INVALID              = "invalid key"
ERROR_DOUBLE_QUOTE_UNTERMINATED = "unterminated double quote"
ERROR_SINGLE_QUOTE_UNTERMINATED = "unterminated single quote"
ERROR_TRAILING_CONTENT         = "trailing content after closing quote"
ERROR_VALUE_INVALID_CHAR       = "value contains whitespace, quote, or backslash"
WARN_KEY_NOT_UPPERCASE         = "is not UPPERCASE (preferred)"


def lint(files, out=sys.stderr):
    """Validate env files. Returns total error count. Diagnostics go to out."""
    total_checked = total_errors = total_warnings = 0
    for f in files:
        c, e, w = _lint_file(f, out)
        total_checked += c
        total_errors += e
        total_warnings += w
    print(f"{total_checked} checked, {total_errors} errors, {total_warnings} warnings", file=out)
    return total_errors


def _lint_file(f, out):
    checked = errors = warnings = 0

    def error(n, msg):
        nonlocal errors
        print(f"ERROR: ({f}:{n}) {msg}", file=out)
        errors += 1

    def warning(n, msg):
        nonlocal warnings
        print(f"WARNING: ({f}:{n}) {msg}", file=out)
        warnings += 1

    with open(f) as fh:
        for n, line in enumerate(fh, 1):
            line = line.rstrip("\n")  # universal newlines mode already strips \r\n → \n
            if not line.strip():
                continue
            if line.startswith("#"):
                continue
            checked += 1

            if "=" not in line:
                error(n, ERROR_NO_EQUALS); continue
            k, v = line.split("=", 1)
            if k != k.lstrip():
                error(n, ERROR_KEY_LEADING_WHITESPACE); continue
            if k != k.rstrip():
                error(n, ERROR_KEY_TRAILING_WHITESPACE); continue
            if v and v != v.lstrip():
                error(n, ERROR_VALUE_LEADING_WHITESPACE); continue
            if not KEY_RE.match(k):
                error(n, f"{ERROR_KEY_INVALID} '{k}'"); continue
            if k != k.upper():
                warning(n, f"key '{k}' {WARN_KEY_NOT_UPPERCASE}")

            if not v:
                continue

            c = v[0]
            if c == '"':
                rest = v[1:]
                pos = rest.find('"')
                if pos == -1:
                    error(n, ERROR_DOUBLE_QUOTE_UNTERMINATED); continue
                if rest[pos + 1:]:
                    error(n, ERROR_TRAILING_CONTENT); continue
            elif c == "'":
                rest = v[1:]
                pos = rest.find("'")
                if pos == -1:
                    error(n, ERROR_SINGLE_QUOTE_UNTERMINATED); continue
                if rest[pos + 1:]:
                    error(n, ERROR_TRAILING_CONTENT); continue
            else:
                if BAD_VAL_RE.search(v):
                    error(n, ERROR_VALUE_INVALID_CHAR); continue

    return checked, errors, warnings


if __name__ == "__main__":
    sys.exit(1 if lint(sys.argv[1:]) > 0 else 0)
