#!/bin/sh
# envfile.sh — validate/normalize env files (POSIX sh)
# Config via ENVFILE_* env vars; see envfile.awk for full docs.
#
# Pipeline: slurp → check_nul → check_bom → strip_crlf → join_continuations → validate

format=${ENVFILE_FORMAT:-shell}
action=${ENVFILE_ACTION:-validate}
if [ -n "${ENVFILE_BOM:-}" ]; then
  bom=$ENVFILE_BOM
elif [ "$format" = native ]; then
  bom=literal
else
  bom=strip
fi
crlf=${ENVFILE_CRLF:-ignore}
nul=${ENVFILE_NUL:-reject}
cont=${ENVFILE_BACKSLASH_CONTINUATION:-ignore}
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)

case "$bom" in literal|strip|reject) ;; *)
  printf '%s: %s\n' "$0" "FATAL_ERROR_BAD_ENVFILE_VALUE: ENVFILE_BOM=$bom" >&2
  exit 1
  ;;
esac
if [ "$format" = native ] && [ "$bom" != literal ]; then
  printf '%s: %s\n' "$0" "FATAL_ERROR_UNSUPPORTED: format=native ENVFILE_BOM=$bom" >&2
  exit 1
fi
# POSIX sh read(1) cannot preserve NUL bytes in lines.
# Delegate NUL=ignore to the awk reference implementation.
if [ "$nul" = ignore ]; then
  [ $# -eq 0 ] && set -- -
  exec env \
    ENVFILE_FORMAT="$format" \
    ENVFILE_ACTION="$action" \
    ENVFILE_BOM="$bom" \
    ENVFILE_CRLF="$crlf" \
    ENVFILE_NUL="$nul" \
    ENVFILE_BACKSLASH_CONTINUATION="$cont" \
    LC_ALL=C \
    "$SCRIPT_DIR/envfile.awk" "$@"
fi

checked=0 errors=0
TAB="$(printf '\t')"
CR="$(printf '\r')"
NUL_SCAN="$SCRIPT_DIR/nullscan"
ENV_STORE=

cleanup() {
  [ -n "$ENV_STORE" ] && rm -f "$ENV_STORE" "$ENV_STORE.tmp"
}
trap cleanup EXIT HUP INT TERM

diag() { printf '%s: %s:%d\n' "$3" "$1" "$2" >&2; errors=$(( errors + 1 )); }
fdiag() { printf '%s: %s\n' "$2" "$1" >&2; errors=$(( errors + 1 )); }

init_env_store() {
  ENV_STORE=$(mktemp "${TMPDIR:-/tmp}/envfile-env.XXXXXX") || exit 1
  env | while IFS= read -r line; do
    case "$line" in
      ENVFILE_*=*) ;;
      *=*) printf '%s\n' "$line" ;;
    esac
  done > "$ENV_STORE"
}

env_get() {
  name=$1
  ENVVAL=
  found=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$name"=*) ENVVAL=${line#*=}; found=1 ;;
    esac
  done < "$ENV_STORE"
  [ "$found" -eq 1 ]
}

env_set() {
  name=$1
  val=$2
  : > "$ENV_STORE.tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$name"=*) ;;
      *=*) printf '%s\n' "$line" >> "$ENV_STORE.tmp" ;;
    esac
  done < "$ENV_STORE"
  printf '%s=%s\n' "$name" "$val" >> "$ENV_STORE.tmp"
  mv "$ENV_STORE.tmp" "$ENV_STORE"
}

emit_env_sorted() {
  : > "$ENV_STORE.tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ENVFILE_*=*) ;;
      *=*) printf '%s\n' "$line" >> "$ENV_STORE.tmp" ;;
    esac
  done < "$ENV_STORE"
  LC_ALL=C sort -t= -k1,1 "$ENV_STORE.tmp"
}

subst_value() {
  val=$1
  path=$2
  lineno=$3
  out=
  while :; do
    case "$val" in
      *'$'*) prefix=${val%%\$*}; out=$out$prefix; rest=${val#*'$'} ;;
      *) out=$out$val; break ;;
    esac

    case "$rest" in
      '{'*)
        after=${rest#\{}
        case "$after" in
          *'}'*) name=${after%%\}*}; val=${after#*\}} ;;
          *) out=$out'$'"$rest"; val=; continue ;;
        esac
        ;;
      [A-Za-z_]*)
        r=$rest
        c=${r%"${r#?}"}
        case "$c" in
          [A-Za-z_]) name=$c; r=${r#?} ;;
          *) out=$out'$'; val=$rest; continue ;;
        esac
        while [ -n "$r" ]; do
          c=${r%"${r#?}"}
          case "$c" in
            [A-Za-z0-9_]) name=$name$c; r=${r#?} ;;
            *) break ;;
          esac
        done
        val=$r
        ;;
      *)
        out=$out'$'
        val=$rest
        continue
        ;;
    esac

    if env_get "$name"; then
      out=$out$ENVVAL
    else
      printf 'LINE_ERROR_UNBOUND_REF (%s): %s:%d\n' "$name" "$path" "$lineno" >&2
      errors=$(( errors + 1 ))
    fi
  done
  SUBST_RESULT=$out
}

do_delta() {
  key=$1
  raw=$2
  value=$3
  path=$4
  lineno=$5
  resolved=$value

  case "$action" in
    validate|normalize|dump) return ;;
  esac

  if [ "$format" = native ]; then
    subst_value "$resolved" "$path" "$lineno"
    resolved=$SUBST_RESULT
  else
    c=${raw%"${raw#?}"}
    if [ "$c" != "'" ]; then
      subst_value "$resolved" "$path" "$lineno"
      resolved=$SUBST_RESULT
    fi
  fi

  env_set "$key" "$resolved"
  [ "$action" = delta ] && printf '%s=%s\n' "$key" "$resolved"
}

# ---------------------------------------------------------------------------
# Stage 1: slurp file into a temp file, return path on stdout
# ---------------------------------------------------------------------------
slurp() {
  tmp=$(mktemp "${TMPDIR:-/tmp}/envfile.XXXXXX") || return 1
  cat > "$tmp"
  printf '%s\n' "$tmp"
}

# ---------------------------------------------------------------------------
# Stage 2: reject files containing NUL bytes (file-level)
# Outputs the temp path on stdout if OK, nothing if rejected.
# ---------------------------------------------------------------------------
check_nul() {
  path=$1; display=$2
  if [ "$nul" = reject ] && ! "$NUL_SCAN" "$path" >/dev/null 2>&1; then
    fdiag "$display" FILE_ERROR_NUL
    rm -f "$path"
    return 1
  fi
  printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# Stage 3: check/stripe UTF-8 BOM from first line
# Modifies file in place; outputs path on stdout.
# ---------------------------------------------------------------------------
check_bom() {
  path=$1; display=$2
  first=$(head -c 3 "$path" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$first" = "efbbbf" ]; then
    case "$bom" in
      reject) fdiag "$display" FILE_ERROR_BOM; rm -f "$path"; return 1 ;;
      strip)  tail -c +4 "$path" > "$path.tmp" && mv "$path.tmp" "$path" ;;
      literal) ;;
    esac
  fi
  printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# Stage 4: strip trailing CR when every line ends with CR
# Modifies file in place; outputs path on stdout.
# ---------------------------------------------------------------------------
strip_crlf() {
  path=$1
  [ "$crlf" != strip ] && { printf '%s\n' "$path"; return; }

  # Check if all non-empty lines end with CR
  all_crlf=1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in
      *"$CR") ;;
      *) all_crlf=0; break ;;
    esac
  done < "$path"

  if [ "$all_crlf" = 1 ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\n' "${line%$CR}"
    done < "$path" > "$path.tmp"
    mv "$path.tmp" "$path"
  fi
  printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# Stage 5: join backslash-continuation lines
# Modifies file in place; outputs path on stdout.
# ---------------------------------------------------------------------------
join_continuations() {
  path=$1
  [ "$cont" != accept ] && { printf '%s\n' "$path"; return; }

  out=$(mktemp "${TMPDIR:-/tmp}/envfile.XXXXXX")
  hold=
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$hold" ]; then
      line="${hold%\\}$line"
      hold=
    fi
    # Count trailing backslashes
    tmp=$line; bs=0
    while case "$tmp" in *\\) tmp="${tmp%\\}";; *) false;; esac; do
      bs=$(( bs + 1 ))
    done
    if [ $(( bs % 2 )) -eq 1 ]; then
      hold=$line
    else
      printf '%s\n' "$line"
    fi
  done < "$path" > "$out"
  [ -n "$hold" ] && printf '%s\n' "$hold"
  mv "$out" "$path"
  printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# Stage 6: validate each line (format-specific rules)
# ---------------------------------------------------------------------------
valid_shell_key() {
  case "$1" in
    [A-Za-z_]*) case "${1#?}" in *[!A-Za-z0-9_]*) return 1 ;; esac; return 0 ;;
  esac; return 1
}

validate_line() {
  display=$1; lineno=$2; line=$3

  # Strip trailing CR for blank/comment detection (all formats)
  trimmed="${line%$CR}"

  # Skip blanks and comments
  case "$trimmed" in
    *[!" $TAB"]*) ;; *) return ;;
  esac
  case "$trimmed" in '#'*) return ;; esac

  checked=$(( checked + 1 ))

  # Normalize mode: emit raw k=v from unmodified line
  case "$line" in
    *=*) ;; *) diag "$display" "$lineno" LINE_ERROR_NO_EQUALS; return ;;
  esac
  raw_k=${line%%=*}; raw_v=${line#*=}
  case "$action" in normalize) printf '%s=%s\n' "$raw_k" "$raw_v"; return ;; esac

  # Validation: use trimmed (CR-stripped) line
  case "$format" in native) work=$line ;; *) work=$trimmed ;; esac
  case "$work" in
    *=*) ;; *) diag "$display" "$lineno" LINE_ERROR_NO_EQUALS; return ;;
  esac
  k=${work%%=*}; v=${work#*=}

  if [ "$format" = native ]; then
    [ -z "$k" ] && { diag "$display" "$lineno" LINE_ERROR_EMPTY_KEY; return; }
    [ "$action" = dump ] && printf '%s=%s\n' "$k" "$v"
    do_delta "$k" "$v" "$v" "$display" "$lineno"
    return
  fi

  # shell format validation
  case "$k" in [[:space:]]*) diag "$display" "$lineno" LINE_ERROR_KEY_LEADING_WHITESPACE; return ;; esac
  case "$k" in *[[:space:]]) diag "$display" "$lineno" LINE_ERROR_KEY_TRAILING_WHITESPACE; return ;; esac
  case "$v" in [[:space:]]*) diag "$display" "$lineno" LINE_ERROR_VALUE_LEADING_WHITESPACE; return ;; esac
  [ -z "$k" ]               && { diag "$display" "$lineno" LINE_ERROR_EMPTY_KEY; return; }
  valid_shell_key "$k"       || { diag "$display" "$lineno" LINE_ERROR_KEY_INVALID; return; }

  # Validate value: check quoting
  if [ -n "$v" ]; then
    c=${v%"${v#?}"}
    case "$c" in
      '"'|"'")
        rest=${v#?}
        case "$rest" in
          *"$c"*)
            after=${rest#*"$c"}
            [ -n "$after" ] && { diag "$display" "$lineno" LINE_ERROR_TRAILING_CONTENT; return; }
            value=${rest%"$c"*}
            ;;
          *) case "$c" in
               '"') diag "$display" "$lineno" LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED ;;
               "'") diag "$display" "$lineno" LINE_ERROR_SINGLE_QUOTE_UNTERMINATED ;;
             esac
             return ;;
        esac
        ;;
      *) case "$v" in
           *" "*|*"$TAB"*|*"'"*|*'"'*|*'\'*)
             diag "$display" "$lineno" LINE_ERROR_VALUE_INVALID_CHAR; return ;;
         esac
         value=$v
         ;;
    esac
  else
    value=
  fi

  [ "$action" = dump ] && printf '%s=%s\n' "$k" "$value"
  do_delta "$k" "$raw_v" "$value" "$display" "$lineno"
}

# ---------------------------------------------------------------------------
# Process one file through the pipeline
# ---------------------------------------------------------------------------
process_file() {
  display=$1; input=$2

  # For non-stdin files, apply NUL/BOM/CRLF/continuation pre-passes
  if [ "$input" != - ]; then
    # NUL check
    if [ "$nul" = reject ]; then
      case "$($NUL_SCAN "$input" >/dev/null 2>&1; echo $?)" in
        0) ;;
        *) fdiag "$display" FILE_ERROR_NUL; return ;;
      esac
    fi

    # BOM check
    first=$(head -c 3 "$input" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$first" = "efbbbf" ]; then
      case "$bom" in
        reject) fdiag "$display" FILE_ERROR_BOM; return ;;
        strip)
          tmp=$(mktemp "${TMPDIR:-/tmp}/envfile.XXXXXX")
          tail -c +4 "$input" > "$tmp"
          input=$tmp
          ;;
      esac
    fi

    # CRLF strip — read into temp if needed
    strip_cr=0
    if [ "$crlf" = strip ]; then
      all_crlf=1
      while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in *"$CR") ;; *) all_crlf=0; break ;; esac
      done < "$input"
      if [ "$all_crlf" = 1 ]; then
        tmp=$(mktemp "${TMPDIR:-/tmp}/envfile.XXXXXX")
        while IFS= read -r line || [ -n "$line" ]; do
          printf '%s\n' "${line%$CR}"
        done < "$input" > "$tmp"
        input=$tmp
        strip_cr=1
      fi
    fi

    # Continuation joining
    if [ "$cont" = accept ]; then
      tmp=$(mktemp "${TMPDIR:-/tmp}/envfile.XXXXXX")
      hold=
      while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "$hold" ]; then
          line="${hold%\\}$line"
          hold=
        fi
        bs_line=$line; bs=0
        while case "$bs_line" in *\\) bs_line="${bs_line%\\}";; *) false;; esac; do
          bs=$(( bs + 1 ))
        done
        if [ $(( bs % 2 )) -eq 1 ]; then
          hold=$line
        else
          printf '%s\n' "$line"
        fi
      done < "$input" > "$tmp"
      [ -n "$hold" ] && printf '%s\n' "$hold" >> "$tmp"
      input=$tmp
    fi
  fi

  # Validate lines
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$(( n + 1 ))
    validate_line "$display" "$n" "$line"
  done < "$input"

  # Clean up temp files
  case "$input" in ${TMPDIR:-/tmp}/*) rm -f "$input" ;; esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
[ $# -eq 0 ] && set -- -

case "$action" in
  delta|apply) init_env_store ;;
esac

for f in "$@"; do
  if [ "$f" = - ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/envfile.XXXXXX") || exit 1
    cat > "$tmp"
    process_file "$f" "$tmp"
    rm -f "$tmp"
  else
    process_file "$f" "$f"
  fi
done

[ "$action" = apply ] && emit_env_sorted

printf '%d checked, %d errors\n' "$checked" "$errors" >&2
[ "$errors" -gt 0 ] && exit 1 || true
