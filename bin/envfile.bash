#!/usr/bin/env bash
# envfile.bash — validate/normalize env files (see README.md)
set -uo pipefail

format=${ENVFILE_FORMAT:-strict}
action=${ENVFILE_ACTION:-validate}
checked=0 errors=0

diag()    { printf '%s: %s:%s\n' "$3" "$1" "$2" >&2; (( errors++ )); }

has_nul() {
  local chunk
  while IFS= read -r -d '' chunk; do
    return 0
  done < "$1"
  return 1
}

native_line() {
  local file=$1 n=$2 line=$3 k v
  case $line in *=*) ;; *)
    diag "$file" "$n" ERROR_NO_EQUALS; return ;;
  esac
  k=${line%%=*}; v=${line#*=}
  [[ -z $k ]]                       && { diag "$file" "$n" ERROR_EMPTY_KEY;  return; }
  [[ $k =~ ^[A-Z_][A-Z0-9_]*$ ]]   || { diag "$file" "$n" ERROR_KEY_INVALID; return; }
  [[ $action == normalize ]] && printf '%s=%s\n' "$k" "$v"
}

strict_line() {
  local file=$1 n=$2 line=$3 k v value c rest after
  case $line in *=*) ;; *)
    diag "$file" "$n" ERROR_NO_EQUALS; return ;;
  esac
  k=${line%%=*}; v=${line#*=}; value=$v

  [[ $k == [[:space:]]* ]]          && { diag "$file" "$n" ERROR_KEY_LEADING_WHITESPACE;   return; }
  [[ $k == *[[:space:]] ]]          && { diag "$file" "$n" ERROR_KEY_TRAILING_WHITESPACE;  return; }
  [[ $v == [[:space:]]* ]]          && { diag "$file" "$n" ERROR_VALUE_LEADING_WHITESPACE; return; }
  [[ $k =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { diag "$file" "$n" ERROR_KEY_INVALID; return; }

  if [[ -n $v ]]; then
    c=${v:0:1}
    if [[ $c == '"' || $c == "'" ]]; then
      rest=${v:1}
      case $rest in
        *"$c"*)
          after=${rest#*"$c"}
          [[ -n $after ]] && { diag "$file" "$n" ERROR_TRAILING_CONTENT; return; }
          value=${rest%%"$c"*}
          ;;
        *) diag "$file" "$n" "$([[ $c == '"' ]] && echo ERROR_DOUBLE_QUOTE_UNTERMINATED || echo ERROR_SINGLE_QUOTE_UNTERMINATED)"
           return ;;
      esac
    else
      case $v in *[[:space:]]*|*\'*|*'"'*|*\\*)
        diag "$file" "$n" ERROR_VALUE_INVALID_CHAR; return ;;
      esac
    fi
  fi

  [[ $action == normalize ]] && printf '%s=%s\n' "$k" "$value"
}

process() {
  local file=$1 n=0 line
  while IFS= read -r line || [[ -n $line ]]; do
    (( n++ ))
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    case $line in '#'*) continue ;; esac
    (( checked++ ))
    if [[ $format == native ]]; then
      native_line "$file" "$n" "$line"
    else
      strict_line "$file" "$n" "${line%$'\r'}"
    fi
  done
}

(( $# == 0 )) && set -- -

for f in "$@"; do
  if [[ $f == - ]]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/envfile.XXXXXX") || exit 1
    cat > "$tmp"
    if has_nul "$tmp"; then
      (( checked++ ))
      diag "$f" 1 ERROR_VALUE_INVALID_CHAR
      rm -f "$tmp"
      continue
    fi
    process "$f" < "$tmp"
    rm -f "$tmp"
  elif has_nul "$f"; then
    (( checked++ ))
    diag "$f" 1 ERROR_VALUE_INVALID_CHAR
  else
    process "$f" < "$f"
  fi
done

printf '%d checked, %d errors\n' "$checked" "$errors" >&2
(( errors )) && exit 1 || true
