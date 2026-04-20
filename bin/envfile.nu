#!/usr/bin/env nu
# envfile.nu — validate/normalize env files

const BOM_BYTES = 0x[ef bb bf]
const CR_BYTE = 0x[0d]
const LF_BYTE = 0x[0a]
const NUL_BYTE = 0x[00]

def fatal [code: string, detail: string] {
  print -e $"($code): ($detail)"
  exit 1
}

def valid_shell_key [key: string] {
  not ($key | parse --regex '^[A-Za-z_][A-Za-z0-9_]*$' | is-empty)
}

def is_blank_spaces_tabs [line: string] {
  not ($line | parse --regex '^[ \t]*$' | is-empty)
}

def is_continuation [line: string] {
  mut n = 0
  mut t = $line
  while ($t | str ends-with "\\") {
    $n += 1
    $t = ($t | str substring 0..<-1)
  }
  ($n mod 2) == 1
}

def split_lines_text [txt: string] {
  mut lines = ($txt | split row "\n")
  if (($lines | length) > 0) and ((($lines | last) | str length) == 0) {
    $lines = ($lines | drop nth (($lines | length) - 1))
  }
  $lines
}

def split_lines_bin [buf: binary] {
  mut lines = ($buf | bytes split $LF_BYTE)
  if (($lines | length) > 0) and ((($lines | last) | bytes length) == 0) {
    $lines = ($lines | drop nth (($lines | length) - 1))
  }
  $lines
}

def unquote_shell_value [path: string, lineno: int, value: string] {
  if (($value | str length) == 0) {
    return {ok: true, value: $value, error: ""}
  }
  let c = ($value | str substring 0..<1)
  if ($c == '"') or ($c == "'") {
    let rest = ($value | str substring 1..)
    let pos = ($rest | str index-of $c)
    if $pos == -1 {
      if $c == '"' {
        return {ok: false, value: "", error: "LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED"}
      } else {
        return {ok: false, value: "", error: "LINE_ERROR_SINGLE_QUOTE_UNTERMINATED"}
      }
    }
    let after = ($rest | str substring ($pos + 1)..)
    if (($after | str length) > 0) {
      return {ok: false, value: "", error: "LINE_ERROR_TRAILING_CONTENT"}
    }
    return {ok: true, value: ($rest | str substring 0..<$pos), error: ""}
  }

  if ($value | str contains " ") or ($value | str contains "\t") or ($value | str contains "'") or ($value | str contains '"') or ($value | str contains "\\") {
    return {ok: false, value: "", error: "LINE_ERROR_VALUE_INVALID_CHAR"}
  }
  {ok: true, value: $value, error: ""}
}

def subst_value [path: string, lineno: int, value: string, env_map: record] {
  mut out = ""
  mut rest = $value
  mut add_errors = 0

  while true {
    let pos = ($rest | str index-of "$")
    if $pos == -1 {
      $out = $out + $rest
      break
    }

    let prefix = ($rest | str substring 0..<$pos)
    $out = $out + $prefix

    if (($pos + 1) >= ($rest | str length)) {
      $out = $out + "$"
      break
    }

    let after_dollar = ($rest | str substring ($pos + 1)..)
    if ($after_dollar | str starts-with "{") {
      let inner = ($after_dollar | str substring 1..)
      let close = ($inner | str index-of "}")
      if $close == -1 {
        $out = $out + "$" + $after_dollar
        break
      }
      let name = ($inner | str substring 0..<$close)
      let remain = ($inner | str substring ($close + 1)..)
      let got = ($env_map | get -o $name)
      if ($got | is-empty) {
        print -e ("LINE_ERROR_UNBOUND_REF (" + $name + "): " + $path + ":" + ($lineno | into string))
        $add_errors += 1
      } else {
        let val = if (($got | describe) == "string") { $got } else { $got | first }
        $out = $out + $val
      }
      $rest = $remain
      continue
    }

    let parsed = ($after_dollar | parse --regex '^(?P<name>[A-Za-z_][A-Za-z0-9_]*)(?P<rest>.*)$')
    if ($parsed | is-empty) {
      $out = $out + "$"
      $rest = $after_dollar
      continue
    }
    let name = $parsed.0.name
    let remain = $parsed.0.rest
    let got = ($env_map | get -o $name)
    if ($got | is-empty) {
      print -e ("LINE_ERROR_UNBOUND_REF (" + $name + "): " + $path + ":" + ($lineno | into string))
      $add_errors += 1
    } else {
      let val = if (($got | describe) == "string") { $got } else { $got | first }
      $out = $out + $val
    }
    $rest = $remain
  }

  {value: $out, add_errors: $add_errors}
}

def seed_env_map [] {
  mut m = {}
  for k in ($env | columns) {
    if not ($k | str starts-with "ENVFILE_") {
      let raw = ($env | get $k)
      let dtype = ($raw | describe)
      let val = (try {
        if ($dtype | str starts-with "list<") {
          ($raw | each {|x| $x | into string} | str join ":")
        } else {
          ($raw | into string)
        }
      } catch {
        null
      })
      if $val != null {
        $m = ($m | upsert $k $val)
      }
    }
  }
  $m
}

def process_file [
  path: string,
  format: string,
  action: string,
  bom: string,
  crlf: string,
  nul: string,
  cont: string,
  env_map: record
] {
  mut checked = 0
  mut errors = 0
  mut map = $env_map

  let file_text = (try {
    if $path == "-" {
      open --raw /dev/stdin
    } else {
      open --raw $path
    }
  } catch {
    print -e $"FILE_ERROR_FILE_UNREADABLE: ($path)"
    return {checked: 0, errors: 1, env_map: $env_map}
  })

  let is_binary = (($file_text | describe) == "binary")

  if ($nul == "reject") and (
    (if $is_binary {
      (($file_text | bytes index-of $NUL_BYTE) != -1)
    } else {
      ($file_text | str contains "\u{0}")
    })
  ) {
    print -e $"FILE_ERROR_NUL: ($path)"
    return {checked: 0, errors: 1, env_map: $map}
  }

  mut lines = if $is_binary {
    mut out = []
    for b in (split_lines_bin $file_text) {
      $out = ($out | append ($b | decode iso-8859-1))
    }
    $out
  } else {
    split_lines_text $file_text
  }

  if (($lines | length) > 0) and (((($lines | get 0) | encode utf-8) | bytes starts-with $BOM_BYTES)) {
    if $bom == "reject" {
      print -e $"FILE_ERROR_BOM: ($path)"
      return {checked: 0, errors: 1, env_map: $map}
    }
    if $bom == "strip" {
      let first = (((($lines | get 0) | encode utf-8) | bytes at 3..) | decode utf-8)
      $lines = ($lines | update 0 $first)
    }
  }

  if $crlf == "strip" {
    mut all_crlf = (($lines | length) > 0)
    for line in $lines {
      if (($line | str length) == 0) or (not ($line | str ends-with "\r")) {
        $all_crlf = false
      }
    }
    if $all_crlf {
      mut stripped = []
      for line in $lines {
        $stripped = ($stripped | append ($line | str substring 0..<-1))
      }
      $lines = $stripped
    }
  }

  mut proc = []
  if $cont == "accept" {
    mut i = 0
    let n = ($lines | length)
    while ($i < $n) {
      mut line = ($lines | get $i)
      mut lineno = ($i + 1)
      $i += 1
      while (is_continuation $line) and ($i < $n) {
        let nxt = ($lines | get $i)
        $line = (($line | str substring 0..<-1) + $nxt)
        $lineno = ($i + 1)
        $i += 1
      }
      $proc = ($proc | append {line: $line, lineno: $lineno})
    }
  } else {
    for item in ($lines | enumerate) {
      $proc = ($proc | append {line: $item.item, lineno: ($item.index + 1)})
    }
  }

  for row in $proc {
    let line = $row.line
    let lineno = $row.lineno
    let trimmed = if ($line | str ends-with "\r") { $line | str substring 0..<-1 } else { $line }

    if (is_blank_spaces_tabs $trimmed) { continue }
    if ($trimmed | str starts-with "#") { continue }

    $checked += 1
    let eq = ($line | str index-of "=")
    if $eq == -1 {
      print -e $"LINE_ERROR_NO_EQUALS: ($path):($lineno)"
      $errors += 1
      continue
    }

    let raw_key = ($line | str substring 0..<$eq)
    let raw_value = ($line | str substring ($eq + 1)..)

    if $action == "normalize" {
      print --raw --no-newline $"($raw_key)=($raw_value)\n"
      continue
    }

    let work = if $format == "native" { $line } else { $trimmed }
    let eq2 = ($work | str index-of "=")
    if $eq2 == -1 {
      print -e $"LINE_ERROR_NO_EQUALS: ($path):($lineno)"
      $errors += 1
      continue
    }

    let key = ($work | str substring 0..<$eq2)
    let value = ($work | str substring ($eq2 + 1)..)

    if $format == "native" {
      if ($key | is-empty) {
        print -e $"LINE_ERROR_EMPTY_KEY: ($path):($lineno)"
        $errors += 1
        continue
      }
      if $action == "dump" {
        print --raw --no-newline $"($key)=($value)\n"
        continue
      }
      if ($action == "delta") or ($action == "apply") {
        let sub = (subst_value $path $lineno $value $map)
        $errors += $sub.add_errors
        $map = ($map | upsert $key $sub.value)
        if $action == "delta" {
          print --raw --no-newline $"($key)=($sub.value)\n"
        }
      }
      continue
    }

    if ($key | str starts-with " ") or ($key | str starts-with "\t") {
      print -e $"LINE_ERROR_KEY_LEADING_WHITESPACE: ($path):($lineno)"
      $errors += 1
      continue
    }
    if ($key | str ends-with " ") or ($key | str ends-with "\t") {
      print -e $"LINE_ERROR_KEY_TRAILING_WHITESPACE: ($path):($lineno)"
      $errors += 1
      continue
    }
    if (($value | str length) > 0) and (($value | str starts-with " ") or ($value | str starts-with "\t")) {
      print -e $"LINE_ERROR_VALUE_LEADING_WHITESPACE: ($path):($lineno)"
      $errors += 1
      continue
    }
    if ($key | is-empty) {
      print -e $"LINE_ERROR_EMPTY_KEY: ($path):($lineno)"
      $errors += 1
      continue
    }
    if not (valid_shell_key $key) {
      print -e $"LINE_ERROR_KEY_INVALID: ($path):($lineno)"
      $errors += 1
      continue
    }

    let uq = (unquote_shell_value $path $lineno $value)
    if not $uq.ok {
      print -e $"($uq.error): ($path):($lineno)"
      $errors += 1
      continue
    }

    if $action == "dump" {
      print --raw --no-newline $"($key)=($uq.value)\n"
      continue
    }
    if ($action == "delta") or ($action == "apply") {
      let resolved = if ($raw_value | str starts-with "'") {
        $uq.value
      } else {
        let sub = (subst_value $path $lineno $uq.value $map)
        $errors += $sub.add_errors
        $sub.value
      }
      $map = ($map | upsert $key $resolved)
      if $action == "delta" {
        print --raw --no-newline $"($key)=($resolved)\n"
      }
    }
  }

  {checked: $checked, errors: $errors, env_map: $map}
}

def main [...files: string] {
  let format = ($env.ENVFILE_FORMAT? | default "shell")
  let action = ($env.ENVFILE_ACTION? | default "validate")
  let bom = ($env.ENVFILE_BOM? | default (if $format == "native" { "literal" } else { "strip" }))
  let crlf = ($env.ENVFILE_CRLF? | default "ignore")
  let nul = ($env.ENVFILE_NUL? | default "reject")
  let cont = ($env.ENVFILE_BACKSLASH_CONTINUATION? | default "ignore")

  if not (($bom == "literal") or ($bom == "strip") or ($bom == "reject")) {
    fatal "FATAL_ERROR_BAD_ENVFILE_VALUE" $"ENVFILE_BOM=($bom)"
  }
  if ($format == "native") and ($bom != "literal") {
    fatal "FATAL_ERROR_UNSUPPORTED" $"format=native ENVFILE_BOM=($bom)"
  }

  let paths = if ($files | is-empty) { ["-"] } else { $files }
  mut env_map = if ($action == "delta") or ($action == "apply") { seed_env_map } else { {} }
  mut checked = 0
  mut errors = 0

  for p in $paths {
    let r = (process_file $p $format $action $bom $crlf $nul $cont $env_map)
    $checked += $r.checked
    $errors += $r.errors
    $env_map = $r.env_map
  }

  if $action == "apply" {
    let rows = ($env_map | transpose key value)
    let keys = ($rows | where {|r| not ($r.key | str starts-with "ENVFILE_")} | get key | sort)
    for k in $keys {
      let v = ($env_map | get $k)
      print --raw --no-newline $"($k)=($v)\n"
    }
  }

  print -e $"($checked) checked, ($errors) errors"
  if $errors > 0 { exit 1 }
}
