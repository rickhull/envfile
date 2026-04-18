#!/bin/sh
# envfile.sh — validate/normalize env files (POSIX sh; see README.md)

format=${ENVFILE_FORMAT:-strict}
action=${ENVFILE_ACTION:-validate}
checked=0 errors=0
TAB="$(printf '\t')" CR="$(printf '\r')"
nullscan=$(CDPATH= cd "$(dirname "$0")" && pwd)/nullscan

diag()    { printf '%s: %s:%s\n' "$3" "$1" "$2" >&2; errors=$(( errors + 1 )); }

has_nul() {
  "$nullscan" "$1" >/dev/null 2>&1
}

valid_strict_key() {
  case "$1" in
    [A-Za-z_]*) case "${1#?}" in *[!A-Za-z0-9_]*) return 1 ;; esac; return 0 ;;
  esac; return 1
}

valid_native_key() {
  case "$1" in
    [A-Z_]*) case "${1#?}" in *[!A-Z0-9_]*) return 1 ;; esac; return 0 ;;
  esac; return 1
}

native_line() {
  file=$1; n=$2; line=$3
  case "$line" in *=*) ;; *) diag "$file" "$n" ERROR_NO_EQUALS; return ;; esac
  k=${line%%=*}; v=${line#*=}
  [ -z "$k" ]                  && { diag "$file" "$n" ERROR_EMPTY_KEY;   return; }
  valid_native_key "$k"        || { diag "$file" "$n" ERROR_KEY_INVALID; return; }
  [ "$action" = normalize ]    && printf '%s=%s\n' "$k" "$v"
}

strict_line() {
  file=$1; n=$2; line=$3
  case "$line" in *=*) ;; *) diag "$file" "$n" ERROR_NO_EQUALS; return ;; esac
  k=${line%%=*}; v=${line#*=}; value=$v

  case "$k" in [[:space:]]*) diag "$file" "$n" ERROR_KEY_LEADING_WHITESPACE;   return ;; esac
  case "$k" in *[[:space:]]) diag "$file" "$n" ERROR_KEY_TRAILING_WHITESPACE;  return ;; esac
  case "$v" in [[:space:]]*) diag "$file" "$n" ERROR_VALUE_LEADING_WHITESPACE; return ;; esac
  valid_strict_key "$k"        || { diag "$file" "$n" ERROR_KEY_INVALID; return; }

  if [ -n "$v" ]; then
    c=${v%"${v#?}"}
    case "$c" in
      '"'|"'")
        rest=${v#?}
        case "$rest" in
          *"$c"*)
            after=${rest#*"$c"}
            [ -n "$after" ] && { diag "$file" "$n" ERROR_TRAILING_CONTENT; return; }
            value=${rest%%"$c"*}
            ;;
          *) case "$c" in
               '"') diag "$file" "$n" ERROR_DOUBLE_QUOTE_UNTERMINATED ;;
               "'") diag "$file" "$n" ERROR_SINGLE_QUOTE_UNTERMINATED ;;
             esac
             return ;;
        esac
        ;;
      *) case "$v" in
           *" "*|*"$TAB"*|*"'"*|*'"'*|*'\'*)
             diag "$file" "$n" ERROR_VALUE_INVALID_CHAR; return ;;
         esac ;;
    esac
  fi

  [ "$action" = normalize ] && printf '%s=%s\n' "$k" "$value"
}

process() {
  display=$1 input=$2
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$(( n + 1 ))
    if [ "$format" != native ]; then line=${line%"$CR"}; fi
    case "$line" in *[!" $TAB"]*) ;; *) continue ;; esac
    case "$line" in '#'*) continue ;; esac
    checked=$(( checked + 1 ))
    if [ "$format" = native ]; then
      native_line "$display" "$n" "$line"
    else
      strict_line "$display" "$n" "$line"
    fi
  done < "$input"
}

[ $# -eq 0 ] && set -- -

for f in "$@"; do
  if [ "$f" = - ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/envfile.XXXXXX") || exit 1
    cat > "$tmp"
    if ! has_nul "$tmp"; then
      checked=$(( checked + 1 ))
      diag "$f" 1 ERROR_VALUE_INVALID_CHAR
      rm -f "$tmp"
      continue
    fi
    process "$f" "$tmp"
    rm -f "$tmp"
  elif ! has_nul "$f"; then
    checked=$(( checked + 1 ))
    diag "$f" 1 ERROR_VALUE_INVALID_CHAR
  else
    process "$f" "$f"
  fi
done

printf '%d checked, %d errors\n' "$checked" "$errors" >&2
[ "$errors" -gt 0 ] && exit 1 || true
