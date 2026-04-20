#!/usr/bin/env python3
"""envfile.py — validate/normalize env files"""

import os
import sys


FORMAT = os.environ.get("ENVFILE_FORMAT", "shell")
ACTION = os.environ.get("ENVFILE_ACTION", "validate")
BOM = os.environ.get("ENVFILE_BOM", "literal" if FORMAT == "native" else "strip")
CRLF = os.environ.get("ENVFILE_CRLF", "ignore")
NUL = os.environ.get("ENVFILE_NUL", "reject")
CONT = os.environ.get("ENVFILE_BACKSLASH_CONTINUATION", "ignore")

BOM_BYTES = b"\xef\xbb\xbf"

checked = 0
errors = 0
env_map = {}


def fatal(code: str, detail: str) -> None:
    print(f"{code}: {detail}", file=sys.stderr)
    raise SystemExit(1)


def diag(path: str, lineno: int, code: str) -> None:
    global errors
    print(f"{code}: {path}:{lineno}", file=sys.stderr)
    errors += 1


def fdiag(path: str, code: str) -> None:
    global errors
    print(f"{code}: {path}", file=sys.stderr)
    errors += 1


def split_lines(buf: bytes) -> list[bytes]:
    lines = buf.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    return lines


def is_continuation(line: bytes) -> bool:
    n = 0
    i = len(line) - 1
    while i >= 0 and line[i] == 0x5C:  # \
        n += 1
        i -= 1
    return (n % 2) == 1


def valid_shell_key(key: bytes) -> bool:
    if not key:
        return False
    c0 = key[0]
    if not (65 <= c0 <= 90 or 97 <= c0 <= 122 or c0 == 95):
        return False
    for c in key[1:]:
        if not (65 <= c <= 90 or 97 <= c <= 122 or 48 <= c <= 57 or c == 95):
            return False
    return True


def unquote_shell_value(path: str, lineno: int, value: bytes) -> bytes | None:
    if not value:
        return value
    c = value[:1]
    if c in (b'"', b"'"):
        rest = value[1:]
        pos = rest.find(c)
        if pos == -1:
            diag(path, lineno, "LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED" if c == b'"' else "LINE_ERROR_SINGLE_QUOTE_UNTERMINATED")
            return None
        if rest[pos + 1 :]:
            diag(path, lineno, "LINE_ERROR_TRAILING_CONTENT")
            return None
        return rest[:pos]
    if any(ch in value for ch in (b" ", b"\t", b"'", b'"', b"\\")):
        diag(path, lineno, "LINE_ERROR_VALUE_INVALID_CHAR")
        return None
    return value


def env_seed() -> None:
    global env_map
    env_map = {}
    if hasattr(os, "environb"):
        for k, v in os.environb.items():
            if k.startswith(b"ENVFILE_"):
                continue
            env_map[k] = v
    else:
        for k, v in os.environ.items():
            if k.startswith("ENVFILE_"):
                continue
            env_map[k.encode("utf-8", "surrogateescape")] = v.encode("utf-8", "surrogateescape")


def subst_value(path: str, lineno: int, value: bytes) -> bytes:
    global errors
    out = bytearray()
    i = 0
    while i < len(value):
        pos = value.find(b"$", i)
        if pos == -1:
            out.extend(value[i:])
            break
        out.extend(value[i:pos])
        if pos + 1 >= len(value):
            out.extend(b"$")
            break

        rest = value[pos + 1 :]
        if rest[:1] == b"{":
            close = rest.find(b"}", 1)
            if close == -1:
                out.extend(b"$")
                out.extend(rest)
                break
            name = rest[1:close]
            i = pos + 1 + close + 1
        else:
            j = 0
            if not (rest and ((65 <= rest[0] <= 90) or (97 <= rest[0] <= 122) or rest[0] == 95)):
                out.extend(b"$")
                i = pos + 1
                continue
            j += 1
            while j < len(rest) and ((65 <= rest[j] <= 90) or (97 <= rest[j] <= 122) or (48 <= rest[j] <= 57) or rest[j] == 95):
                j += 1
            name = rest[:j]
            i = pos + 1 + j

        if name in env_map:
            out.extend(env_map[name])
        else:
            print(f"LINE_ERROR_UNBOUND_REF ({name.decode('latin1')}): {path}:{lineno}", file=sys.stderr)
            errors += 1

    return bytes(out)


def handle_record(path: str, lineno: int, key: bytes, raw_value: bytes, value: bytes) -> None:
    if ACTION == "dump":
        sys.stdout.buffer.write(key + b"=" + value + b"\n")
        return
    if ACTION in ("validate", "normalize"):
        return

    resolved = value
    if FORMAT == "native" or not raw_value.startswith(b"'"):
        resolved = subst_value(path, lineno, resolved)
    env_map[key] = resolved

    if ACTION == "delta":
        sys.stdout.buffer.write(key + b"=" + resolved + b"\n")


def process_file(path: str, file_bytes: bytes) -> None:
    global checked

    if NUL == "reject" and b"\x00" in file_bytes:
        fdiag(path, "FILE_ERROR_NUL")
        return

    lines = split_lines(file_bytes)

    if lines and lines[0].startswith(BOM_BYTES):
        if BOM == "reject":
            fdiag(path, "FILE_ERROR_BOM")
            return
        if BOM == "strip":
            lines[0] = lines[0][3:]

    if CRLF == "strip":
        all_crlf = all(line.endswith(b"\r") for line in lines) if lines else False
        if all_crlf:
            lines = [line[:-1] for line in lines]

    proc_lines: list[bytes] = []
    proc_lineno: list[int] = []
    if CONT == "accept":
        i = 0
        while i < len(lines):
            line = lines[i]
            lineno = i + 1
            i += 1
            while is_continuation(line) and i < len(lines):
                line = line[:-1] + lines[i]
                lineno = i + 1
                i += 1
            proc_lines.append(line)
            proc_lineno.append(lineno)
    else:
        for i, line in enumerate(lines, start=1):
            proc_lines.append(line)
            proc_lineno.append(i)

    for line, lineno in zip(proc_lines, proc_lineno, strict=False):
        trimmed = line[:-1] if line.endswith(b"\r") else line
        if all(c in (0x20, 0x09) for c in trimmed):
            continue
        if trimmed.startswith(b"#"):
            continue

        checked += 1
        eq = line.find(b"=")
        if eq == -1:
            diag(path, lineno, "LINE_ERROR_NO_EQUALS")
            continue
        raw_key = line[:eq]
        raw_value = line[eq + 1 :]

        if ACTION == "normalize":
            sys.stdout.buffer.write(raw_key + b"=" + raw_value + b"\n")
            continue

        work = line if FORMAT == "native" else trimmed
        eq2 = work.find(b"=")
        if eq2 == -1:
            diag(path, lineno, "LINE_ERROR_NO_EQUALS")
            continue
        key = work[:eq2]
        value = work[eq2 + 1 :]

        if FORMAT == "native":
            if not key:
                diag(path, lineno, "LINE_ERROR_EMPTY_KEY")
                continue
            handle_record(path, lineno, key, raw_value, value)
            continue

        if key and key[0] in (0x20, 0x09):
            diag(path, lineno, "LINE_ERROR_KEY_LEADING_WHITESPACE")
            continue
        if key and key[-1] in (0x20, 0x09):
            diag(path, lineno, "LINE_ERROR_KEY_TRAILING_WHITESPACE")
            continue
        if value and value[0] in (0x20, 0x09):
            diag(path, lineno, "LINE_ERROR_VALUE_LEADING_WHITESPACE")
            continue
        if not key:
            diag(path, lineno, "LINE_ERROR_EMPTY_KEY")
            continue
        if not valid_shell_key(key):
            diag(path, lineno, "LINE_ERROR_KEY_INVALID")
            continue

        unquoted = unquote_shell_value(path, lineno, value)
        if unquoted is None:
            continue
        handle_record(path, lineno, key, raw_value, unquoted)


def main() -> int:
    global errors

    if BOM not in ("literal", "strip", "reject"):
        fatal("FATAL_ERROR_BAD_ENVFILE_VALUE", f"ENVFILE_BOM={BOM}")
    if FORMAT == "native" and BOM != "literal":
        fatal("FATAL_ERROR_UNSUPPORTED", f"format=native ENVFILE_BOM={BOM}")

    files = sys.argv[1:] or ["-"]
    if ACTION in ("delta", "apply"):
        env_seed()

    for path in files:
        try:
            if path == "-":
                data = sys.stdin.buffer.read()
            else:
                with open(path, "rb") as fh:
                    data = fh.read()
        except OSError:
            fdiag(path, "FILE_ERROR_FILE_UNREADABLE")
            continue
        process_file(path, data)

    if ACTION == "apply":
        for key in sorted(k for k in env_map if not k.startswith(b"ENVFILE_")):
            sys.stdout.buffer.write(key + b"=" + env_map[key] + b"\n")

    print(f"{checked} checked, {errors} errors", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
