#!/usr/bin/env bash
# lint — validate env files (see README.md)
set -uo pipefail

if (( $# == 0 )); then
  echo "lint: no files specified" >&2
  exit 1
fi

key_re='^[A-Za-z_][A-Za-z0-9_]*$'
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

for f in "$@"; do
  line_num=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"  # strip carriage return for \r\n (Windows) line endings
    (( line_num++ )) || true

    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" ]] && continue
    [[ "$line" == '#'* ]] && continue

    (( checked++ )) || true

    if [[ "$line" != *"="* ]]; then
      echo "$f:$line_num: $ERROR_NO_EQUALS" >&2; (( errors++ )) || true; continue
    fi

    k="${line%%=*}"
    v="${line#*=}"

    if [[ "$k" != "${k#"${k%%[![:space:]]*}"}" ]]; then
      echo "$f:$line_num: $ERROR_KEY_LEADING_WHITESPACE" >&2; (( errors++ )) || true; continue
    fi
    k_trailing="${k%"${k##*[![:space:]]}"}"
    if [[ "$k" != "$k_trailing" ]]; then
      echo "$f:$line_num: $ERROR_KEY_TRAILING_WHITESPACE" >&2; (( errors++ )) || true; continue
    fi
    v_leading="${v#"${v%%[![:space:]]*}"}"
    if [[ "$v" != "$v_leading" && -n "$v" ]]; then
      echo "$f:$line_num: $ERROR_VALUE_LEADING_WHITESPACE" >&2; (( errors++ )) || true; continue
    fi
    if [[ ! "$k" =~ $key_re ]]; then
      echo "$f:$line_num: $ERROR_KEY_INVALID '$k'" >&2; (( errors++ )) || true; continue
    fi
    if [[ "$k" != "${k^^*}" ]]; then
      echo "$f:$line_num: key '$k' $WARN_KEY_NOT_UPPERCASE" >&2; (( warnings++ )) || true
    fi

    if [[ -z "$v" ]]; then
      continue
    fi

    c="${v:0:1}"
    if [[ "$c" == '"' ]]; then
      rest="${v:1}"
      if [[ "$rest" != *'"'* ]]; then
        echo "$f:$line_num: $ERROR_DOUBLE_QUOTE_UNTERMINATED" >&2; (( errors++ )) || true; continue
      fi
      after="${rest#*\"}"
      if [[ -n "$after" ]]; then
        echo "$f:$line_num: $ERROR_TRAILING_CONTENT" >&2; (( errors++ )) || true; continue
      fi
    elif [[ "$c" == "'" ]]; then
      rest="${v:1}"
      if [[ "$rest" != *"'"* ]]; then
        echo "$f:$line_num: $ERROR_SINGLE_QUOTE_UNTERMINATED" >&2; (( errors++ )) || true; continue
      fi
      after="${rest#*\'}"
      if [[ -n "$after" ]]; then
        echo "$f:$line_num: $ERROR_TRAILING_CONTENT" >&2; (( errors++ )) || true; continue
      fi
    else
      sq="'"
      bad_val_re="[[:space:]${sq}\"\\\\]"
      if [[ "$v" =~ $bad_val_re ]]; then
        echo "$f:$line_num: $ERROR_VALUE_INVALID_CHAR" >&2; (( errors++ )) || true; continue
      fi
    fi
  done < "$f"
done

echo "$checked checked, $errors errors, $warnings warnings" >&2
if (( errors )); then
  exit 1
fi
