#!/usr/bin/env nu
# envfile.nu — validate env files (see README.md)

const ERROR_NO_EQUALS                 = "ERROR_NO_EQUALS"
const ERROR_EMPTY_KEY                 = "ERROR_EMPTY_KEY"
const ERROR_KEY_LEADING_WHITESPACE    = "ERROR_KEY_LEADING_WHITESPACE"
const ERROR_KEY_TRAILING_WHITESPACE   = "ERROR_KEY_TRAILING_WHITESPACE"
const ERROR_VALUE_LEADING_WHITESPACE  = "ERROR_VALUE_LEADING_WHITESPACE"
const ERROR_KEY_INVALID               = "ERROR_KEY_INVALID"
const ERROR_DOUBLE_QUOTE_UNTERMINATED = "ERROR_DOUBLE_QUOTE_UNTERMINATED"
const ERROR_SINGLE_QUOTE_UNTERMINATED = "ERROR_SINGLE_QUOTE_UNTERMINATED"
const ERROR_TRAILING_CONTENT          = "ERROR_TRAILING_CONTENT"
const ERROR_VALUE_INVALID_CHAR        = "ERROR_VALUE_INVALID_CHAR"

def valid_strict_key [key: string] {
  not ($key | parse --regex '^[A-Za-z_][A-Za-z0-9_]*$' | is-empty)
}

def valid_native_key [key: string] {
  not ($key | parse --regex '^[A-Z_][A-Z0-9_]*$' | is-empty)
}

def process_native [f: string, lines: list<string>, action: string] {
  mut checked = 0; mut errors = 0

  for item in ($lines | enumerate) {
    let n = $item.index + 1
    let line = $item.item
    if (($line | encode utf-8 | bytes index-of (bytes build 0)) != -1) {
      print -e $"($ERROR_VALUE_INVALID_CHAR): ($f):($n)"
      $checked += 1
      $errors += 1
      continue
    }
    if ($line | str trim | is-empty) { continue }
    if ($line | str starts-with '#') { continue }
    $checked += 1

    let eq = ($line | str index-of '=')
    if $eq == -1 {
      print -e $"($ERROR_NO_EQUALS): ($f):($n)"
      $errors += 1; continue
    }

    let k = ($line | str substring 0..<$eq)
    let v = ($line | str substring ($eq + 1)..)

    if ($k | is-empty) {
      print -e $"($ERROR_EMPTY_KEY): ($f):($n)"
      $errors += 1; continue
    }
    if not (valid_native_key $k) {
      print -e $"($ERROR_KEY_INVALID): ($f):($n)"
      $errors += 1; continue
    }

    if $action == "normalize" { print $"($k)=($v)" }
  }

  {checked: $checked, errors: $errors}
}

def process_strict [f: string, lines: list<string>, action: string] {
  mut checked = 0; mut errors = 0

  for item in ($lines | enumerate) {
    let n = $item.index + 1
    let line = $item.item
    if (($line | encode utf-8 | bytes index-of (bytes build 0)) != -1) {
      print -e $"($ERROR_VALUE_INVALID_CHAR): ($f):($n)"
      $checked += 1
      $errors += 1
      continue
    }
    if ($line | str trim | is-empty) { continue }
    if ($line | str starts-with '#') { continue }
    $checked += 1

    let eq = ($line | str index-of '=')
    if $eq == -1 {
      print -e $"($ERROR_NO_EQUALS): ($f):($n)"
      $errors += 1; continue
    }

    let k = ($line | str substring 0..<$eq)
    let v = ($line | str substring ($eq + 1)..)

    if ($k | str starts-with ' ') or ($k | str starts-with "\t") {
      print -e $"($ERROR_KEY_LEADING_WHITESPACE): ($f):($n)"; $errors += 1; continue
    }
    if ($k | str ends-with ' ') or ($k | str ends-with "\t") {
      print -e $"($ERROR_KEY_TRAILING_WHITESPACE): ($f):($n)"; $errors += 1; continue
    }
    if ($v | str length) > 0 and (($v | str starts-with ' ') or ($v | str starts-with "\t")) {
      print -e $"($ERROR_VALUE_LEADING_WHITESPACE): ($f):($n)"; $errors += 1; continue
    }
    if not (valid_strict_key $k) {
      print -e $"($ERROR_KEY_INVALID): ($f):($n)"; $errors += 1; continue
    }
    if ($v | str length) == 0 {
      if $action == "normalize" { print $"($k)=($v)" }
      continue
    }

    let c = ($v | str substring 0..<1)
    if $c == '"' or $c == "'" {
      let rest = ($v | str substring 1..)
      let pos = ($rest | str index-of $c)
      if $pos == -1 {
        let code = if $c == '"' { $ERROR_DOUBLE_QUOTE_UNTERMINATED } else { $ERROR_SINGLE_QUOTE_UNTERMINATED }
        print -e $"($code): ($f):($n)"; $errors += 1; continue
      }
      let after = ($rest | str substring ($pos + 1)..)
      if ($after | str length) > 0 {
        print -e $"($ERROR_TRAILING_CONTENT): ($f):($n)"; $errors += 1; continue
      }
      let value = ($rest | str substring 0..<$pos)
      if $action == "normalize" { print $"($k)=($value)" }
    } else {
      if ($v | str contains ' ') or ($v | str contains "'") or ($v | str contains '"') or ($v | str contains "\\") {
        print -e $"($ERROR_VALUE_INVALID_CHAR): ($f):($n)"; $errors += 1; continue
      }
      if $action == "normalize" { print $"($k)=($v)" }
    }
  }

  {checked: $checked, errors: $errors}
}

def main [...files: string] {
  let mode   = ($env.ENVFILE_FORMAT? | default "strict")
  let action = ($env.ENVFILE_ACTION? | default "validate")
  let stdin_text = $in
  let files = if ($files | is-empty) { ["-"] } else { $files }

  mut checked = 0; mut errors = 0

  for f in $files {
    let raw_lines = if $f == "-" {
      $stdin_text | split row "\n"
    } else {
      open --raw $f | decode utf-8 | split row "\n"
    }

    let r = if $mode == "native" {
      process_native $f $raw_lines $action
    } else {
      let lines = $raw_lines | each { |it| $it | str trim --char "\r" }
      process_strict $f $lines $action
    }

    $checked += $r.checked
    $errors  += $r.errors
  }

  print -e $"($checked) checked, ($errors) errors"
  if $errors > 0 { exit 1 }
}
