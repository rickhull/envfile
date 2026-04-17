#!/bin/sh
# shlint — validate env files (POSIX sh; see README.md)

if [ $# -eq 0 ]; then
  echo "shlint: no files specified" >&2
  exit 1
fi

TAB="$(printf '\t')"
CR="$(printf '\r')"  # carriage return, for stripping \r\n (Windows) line endings
checked=0 errors=0 warnings=0

readonly ERROR_NO_EQUALS="missing assignment (=)"
readonly ERROR_KEY_LEADING_WHITESPACE="leading whitespace before key"
readonly ERROR_KEY_TRAILING_WHITESPACE="whitespace before ="
readonly ERROR_VALUE_LEADING_WHITESPACE="whitespace after ="
readonly ERROR_KEY_INVALID="invalid key"
readonly ERROR_DOUBLE_QUOTE_UNTERMINATED="unterminated double quote"
readonly ERROR_SINGLE_QUOTE_UNTERMINATED="unterminated single quote"
readonly ERROR_TRAILING_CONTENT="trailing content after closing quote"
readonly ERROR_VALUE_INVALID_CHAR="value contains whitespace, quote, or backslash"
readonly WARN_KEY_NOT_UPPERCASE="is not UPPERCASE (preferred)"

valid_key() {
  case "$1" in
    [A-Za-z_]*) : ;;
    *) return 1 ;;
  esac
  rest="${1#?}"
  case "$rest" in
    *[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

is_upper() {
  case "$1" in
    *[a-z]*) return 1 ;;
  esac
  return 0
}

has_leading_ws() {
  case "$1" in
    " "*|"$TAB"*) return 0 ;;
  esac
  return 1
}

has_trailing_ws() {
  case "$1" in
    *" "|*"$TAB") return 0 ;;
  esac
  return 1
}

has_bad_unquoted() {
  case "$1" in
    *" "*|*"$TAB"*|*"'"*|*'"'*|*"\\"*) return 0 ;;
  esac
  return 1
}

for f in "$@"; do
  line_num=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$(( line_num + 1 ))
    line="${line%"$CR"}"  # strip carriage return for \r\n (Windows) line endings

    trimmed="${line#"${line%%[!" $TAB"]*}"}"
    trimmed="${trimmed%"${trimmed##*[!" $TAB"]}"}"
    [ -z "$trimmed" ] && continue
    case "$line" in '#'*) continue ;; esac

    checked=$(( checked + 1 ))

    case "$line" in
      *=*) : ;;
      *)
        echo "ERROR: ($f:$line_num) $ERROR_NO_EQUALS" >&2
        errors=$(( errors + 1 )); continue ;;
    esac

    k="${line%%=*}"
    v="${line#*=}"

    if has_leading_ws "$k"; then
      echo "ERROR: ($f:$line_num) $ERROR_KEY_LEADING_WHITESPACE" >&2
      errors=$(( errors + 1 )); continue
    fi

    if has_trailing_ws "$k"; then
      echo "ERROR: ($f:$line_num) $ERROR_KEY_TRAILING_WHITESPACE" >&2
      errors=$(( errors + 1 )); continue
    fi

    if [ -n "$v" ] && has_leading_ws "$v"; then
      echo "ERROR: ($f:$line_num) $ERROR_VALUE_LEADING_WHITESPACE" >&2
      errors=$(( errors + 1 )); continue
    fi

    if ! valid_key "$k"; then
      echo "ERROR: ($f:$line_num) $ERROR_KEY_INVALID '$k'" >&2
      errors=$(( errors + 1 )); continue
    fi

    if ! is_upper "$k"; then
      echo "WARNING: ($f:$line_num) key '$k' $WARN_KEY_NOT_UPPERCASE" >&2
      warnings=$(( warnings + 1 ))
    fi

    [ -z "$v" ] && continue

    c="${v%"${v#?}"}"

    case "$c" in
      '"')
        rest="${v#?}"
        case "$rest" in
          *'"'*)
            after="${rest#*\"}"
            if [ -n "$after" ]; then
              echo "ERROR: ($f:$line_num) $ERROR_TRAILING_CONTENT" >&2
              errors=$(( errors + 1 )); continue
            fi ;;
          *)
            echo "ERROR: ($f:$line_num) $ERROR_DOUBLE_QUOTE_UNTERMINATED" >&2
            errors=$(( errors + 1 )); continue ;;
        esac ;;
      "'")
        rest="${v#?}"
        case "$rest" in
          *"'"*)
            after="${rest#*\'}"
            if [ -n "$after" ]; then
              echo "ERROR: ($f:$line_num) $ERROR_TRAILING_CONTENT" >&2
              errors=$(( errors + 1 )); continue
            fi ;;
          *)
            echo "ERROR: ($f:$line_num) $ERROR_SINGLE_QUOTE_UNTERMINATED" >&2
            errors=$(( errors + 1 )); continue ;;
        esac ;;
      *)
        if has_bad_unquoted "$v"; then
          echo "ERROR: ($f:$line_num) $ERROR_VALUE_INVALID_CHAR" >&2
          errors=$(( errors + 1 )); continue
        fi ;;
    esac
  done < "$f"
done

echo "$checked checked, $errors errors, $warnings warnings" >&2
if [ "$errors" -gt 0 ]; then
  exit 1
fi
