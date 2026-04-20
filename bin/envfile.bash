#!/usr/bin/env bash
# envfile.bash — validate/normalize env files (bash implementation)
set -uo pipefail

format=${ENVFILE_FORMAT:-shell}
action=${ENVFILE_ACTION:-validate}
if [[ -n ${ENVFILE_BOM:-} ]]; then
  bom=$ENVFILE_BOM
elif [[ $format == native ]]; then
  bom=literal
else
  bom=strip
fi
crlf=${ENVFILE_CRLF:-ignore}
nul=${ENVFILE_NUL:-reject}
cont=${ENVFILE_BACKSLASH_CONTINUATION:-ignore}

checked=0
errors=0
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
nullscan="$script_dir/nullscan"

declare -A env_map
declare -a lines
declare -a merged_lines
declare -a merged_linenos

diag() {
  printf '%s: %s:%d\n' "$3" "$1" "$2" >&2
  (( errors++ ))
}

fdiag() {
  printf '%s: %s\n' "$2" "$1" >&2
  (( errors++ ))
}

is_continuation() {
  local s=$1 n=0
  while [[ $s == *\\ ]]; do
    s=${s%\\}
    (( n++ ))
  done
  (( n % 2 == 1 ))
}

unquote_shell_value() {
  local v=$1 path=$2 lineno=$3 c rest after
  UNQUOTED=

  if [[ -z $v ]]; then
    return 0
  fi

  c=${v:0:1}
  if [[ $c == '"' || $c == "'" ]]; then
    rest=${v:1}
    case $rest in
      *"$c"*)
        after=${rest#*"$c"}
        if [[ -n $after ]]; then
          diag "$path" "$lineno" LINE_ERROR_TRAILING_CONTENT
          return 1
        fi
        UNQUOTED=${rest%%"$c"*}
        return 0
        ;;
      *)
        if [[ $c == '"' ]]; then
          diag "$path" "$lineno" LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED
        else
          diag "$path" "$lineno" LINE_ERROR_SINGLE_QUOTE_UNTERMINATED
        fi
        return 1
        ;;
    esac
  fi

  case $v in
    *" "*|*$'\t'*|*"'"*|*'"'*|*\\*)
      diag "$path" "$lineno" LINE_ERROR_VALUE_INVALID_CHAR
      return 1
      ;;
  esac

  UNQUOTED=$v
  return 0
}

subst_value() {
  local val=$1 path=$2 lineno=$3 out= prefix rest name

  while [[ $val == *'$'* ]]; do
    prefix=${val%%\$*}
    out+=$prefix
    rest=${val#*'$'}

    if [[ ${rest:0:1} == '{' ]]; then
      if [[ $rest =~ ^\{([^}]*)\}(.*)$ ]]; then
        name=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
      else
        out+='$'
        out+=$rest
        val=
        break
      fi
    else
      if [[ $rest =~ ^([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]]; then
        name=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
      else
        out+='$'
        val=$rest
        continue
      fi
    fi

    if [[ -v env_map["$name"] ]]; then
      out+=${env_map["$name"]}
    else
      printf 'LINE_ERROR_UNBOUND_REF (%s): %s:%d\n' "$name" "$path" "$lineno" >&2
      (( errors++ ))
    fi
  done

  out+=$val
  SUBST_OUT=$out
}

delta_value() {
  local key=$1 raw=$2 value=$3 path=$4 lineno=$5 resolved=$value

  [[ $action == validate || $action == dump || $action == normalize ]] && return

  if [[ $format == native || ${raw:0:1} != "'" ]]; then
    subst_value "$resolved" "$path" "$lineno"
    resolved=$SUBST_OUT
  fi

  env_map["$key"]=$resolved
  [[ $action == delta ]] && printf '%s=%s\n' "$key" "$resolved"
}

handle_valid_record() {
  local key=$1 raw=$2 value=$3 path=$4 lineno=$5
  case $action in
    dump) printf '%s=%s\n' "$key" "$value" ;;
    delta|apply) delta_value "$key" "$raw" "$value" "$path" "$lineno" ;;
  esac
}

validate_record() {
  local path=$1 lineno=$2 line=$3
  local trimmed raw_k raw_v work k v

  trimmed=${line%$'\r'}
  [[ $trimmed =~ ^[[:space:]]*$ ]] && return
  [[ $trimmed == \#* ]] && return

  (( checked++ ))

  if [[ $line != *=* ]]; then
    diag "$path" "$lineno" LINE_ERROR_NO_EQUALS
    return
  fi
  raw_k=${line%%=*}
  raw_v=${line#*=}

  if [[ $action == normalize ]]; then
    printf '%s=%s\n' "$raw_k" "$raw_v"
    return
  fi

  if [[ $format == native ]]; then
    work=$line
  else
    work=$trimmed
  fi

  if [[ $work != *=* ]]; then
    diag "$path" "$lineno" LINE_ERROR_NO_EQUALS
    return
  fi
  k=${work%%=*}
  v=${work#*=}

  if [[ $format == native ]]; then
    if [[ -z $k ]]; then
      diag "$path" "$lineno" LINE_ERROR_EMPTY_KEY
      return
    fi
    handle_valid_record "$k" "$raw_v" "$v" "$path" "$lineno"
    return
  fi

  [[ $k == [[:space:]]* ]] && { diag "$path" "$lineno" LINE_ERROR_KEY_LEADING_WHITESPACE; return; }
  [[ $k == *[[:space:]] ]] && { diag "$path" "$lineno" LINE_ERROR_KEY_TRAILING_WHITESPACE; return; }
  [[ $v == [[:space:]]* ]] && { diag "$path" "$lineno" LINE_ERROR_VALUE_LEADING_WHITESPACE; return; }
  [[ -z $k ]] && { diag "$path" "$lineno" LINE_ERROR_EMPTY_KEY; return; }
  [[ $k =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { diag "$path" "$lineno" LINE_ERROR_KEY_INVALID; return; }

  unquote_shell_value "$v" "$path" "$lineno" || return
  handle_valid_record "$k" "$raw_v" "$UNQUOTED" "$path" "$lineno"
}

emit_env_sorted() {
  local key
  while IFS= read -r key; do
    [[ -z $key || $key == ENVFILE_* ]] && continue
    printf '%s=%s\n' "$key" "${env_map["$key"]}"
  done < <(printf '%s\n' "${!env_map[@]}" | LC_ALL=C sort)
}

slurp_file_lines() {
  local path=$1 line
  lines=()
  while IFS= read -r line || [[ -n $line ]]; do
    lines+=("$line")
  done < "$path"
}

join_continuations() {
  local hold= line lineno i
  merged_lines=()
  merged_linenos=()

  if [[ $cont != accept ]]; then
    merged_lines=("${lines[@]}")
    for i in "${!lines[@]}"; do
      merged_linenos+=( "$(( i + 1 ))" )
    done
    return
  fi

  for i in "${!lines[@]}"; do
    line=${lines[$i]}
    lineno=$(( i + 1 ))

    if [[ -n $hold ]]; then
      line=${hold%\\}$line
      hold=
    fi

    if is_continuation "$line"; then
      hold=$line
      continue
    fi

    merged_lines+=("$line")
    merged_linenos+=("$lineno")
  done

  if [[ -n $hold ]]; then
    merged_lines+=("$hold")
    merged_linenos+=( "${#lines[@]}" )
  fi
}

strip_all_crlf_if_needed() {
  local all_crlf=1 i
  [[ $crlf != strip ]] && return

  for i in "${!lines[@]}"; do
    [[ ${lines[$i]} == *$'\r' ]] || { all_crlf=0; break; }
  done
  (( all_crlf == 0 )) && return

  for i in "${!lines[@]}"; do
    lines[$i]=${lines[$i]%$'\r'}
  done
}

check_bom_if_needed() {
  local path=$1 display=$2 first
  first=$(LC_ALL=C head -c 3 -- "$path" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [[ $first != efbbbf ]]; then
    return 0
  fi

  case $bom in
    literal)
      ;;
    reject)
      fdiag "$display" FILE_ERROR_BOM
      return 1
      ;;
    strip)
      if ((${#lines[@]} > 0)); then
        lines[0]=${lines[0]#$'\xEF\xBB\xBF'}
      fi
      ;;
  esac

  return 0
}

process_file() {
  local display=$1 input=$2 work line
  local i

  if [[ $input == - ]]; then
    work=$(mktemp "${TMPDIR:-/tmp}/envfile.XXXXXX") || exit 1
    cat > "$work"
  else
    if [[ ! -r $input ]]; then
      fdiag "$display" FILE_ERROR_FILE_UNREADABLE
      return
    fi
    work=$input
  fi

  if [[ $nul == reject ]] && ! "$nullscan" "$work" >/dev/null 2>&1; then
    fdiag "$display" FILE_ERROR_NUL
    [[ $input == - ]] && rm -f "$work"
    return
  fi

  slurp_file_lines "$work"
  check_bom_if_needed "$work" "$display" || { [[ $input == - ]] && rm -f "$work"; return; }
  strip_all_crlf_if_needed
  join_continuations

  for i in "${!merged_lines[@]}"; do
    line=${merged_lines[$i]}
    validate_record "$display" "${merged_linenos[$i]}" "$line"
  done

  [[ $input == - ]] && rm -f "$work"
}

seed_env() {
  local entry k v
  while IFS= read -r -d '' entry; do
    k=${entry%%=*}
    v=${entry#*=}
    [[ $k == ENVFILE_* ]] && continue
    env_map["$k"]=$v
  done < <(env -0)
}

if [[ $bom != literal && $bom != strip && $bom != reject ]]; then
  printf 'FATAL_ERROR_BAD_ENVFILE_VALUE: ENVFILE_BOM=%s\n' "$bom" >&2
  exit 1
fi
if [[ $format == native && $bom != literal ]]; then
  printf 'FATAL_ERROR_UNSUPPORTED: format=native ENVFILE_BOM=%s\n' "$bom" >&2
  exit 1
fi

# Bash cannot preserve NUL bytes in variables. Delegate ignore mode to the
# reference awk backend, which supports byte-transparent processing.
if [[ $nul == ignore ]]; then
  (( $# == 0 )) && set -- -
  exec env \
    ENVFILE_FORMAT="$format" \
    ENVFILE_ACTION="$action" \
    ENVFILE_BOM="$bom" \
    ENVFILE_CRLF="$crlf" \
    ENVFILE_NUL="$nul" \
    ENVFILE_BACKSLASH_CONTINUATION="$cont" \
    LC_ALL=C \
    "$script_dir/envfile.awk" "$@"
fi

if [[ $action == delta || $action == apply ]]; then
  seed_env
fi

(( $# == 0 )) && set -- -
for f in "$@"; do
  process_file "$f" "$f"
done

if [[ $action == apply ]]; then
  emit_env_sorted
fi

printf '%d checked, %d errors\n' "$checked" "$errors" >&2
(( errors > 0 )) && exit 1 || true
