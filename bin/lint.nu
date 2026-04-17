#!/usr/bin/env nu
# nulint — validate env files (see README.md)

const ERROR_NO_EQUALS                = "missing assignment (=)"
const ERROR_KEY_LEADING_WHITESPACE   = "leading whitespace before key"
const ERROR_KEY_TRAILING_WHITESPACE  = "whitespace before ="
const ERROR_VALUE_LEADING_WHITESPACE = "whitespace after ="
const ERROR_KEY_INVALID              = "invalid key"
const ERROR_DOUBLE_QUOTE_UNTERMINATED = "unterminated double quote"
const ERROR_SINGLE_QUOTE_UNTERMINATED = "unterminated single quote"
const ERROR_TRAILING_CONTENT         = "trailing content after closing quote"
const ERROR_VALUE_INVALID_CHAR       = "value contains whitespace, quote, or backslash"
const WARN_KEY_NOT_UPPERCASE         = "is not UPPERCASE (preferred)"

def main [...files: string] {
  if ($files | is-empty) {
    print -e "nulint: no files specified"
    exit 1
  }

  mut checked = 0
  mut errors = 0
  mut warnings = 0

  for $f in $files {
    let lines = (open $f | lines)
    for item in ($lines | enumerate) {
      let n = ($item.index + 1)
      let line = $item.item
      if ($line | str trim | is-empty) { continue }
      if ($line | str starts-with '#') { continue }

      $checked += 1

      if not ($line | str contains '=') {
        print -e ("ERROR: (" + $f + ":" + ($n | into string) + ") " + $ERROR_NO_EQUALS)
        $errors += 1
        continue
      }

      let eq_idx = ($line | str index-of '=')
      let k = ($line | str substring 0..<($eq_idx))
      let v = ($line | str substring ($eq_idx + 1)..)

      if (($k | str starts-with ' ') or ($k | str starts-with "\t")) {
        print -e ("ERROR: (" + $f + ":" + ($n | into string) + ") " + $ERROR_KEY_LEADING_WHITESPACE)
        $errors += 1
        continue
      }
      if (($k | str ends-with ' ') or ($k | str ends-with "\t")) {
        print -e ("ERROR: (" + $f + ":" + ($n | into string) + ") " + $ERROR_KEY_TRAILING_WHITESPACE)
        $errors += 1
        continue
      }
      if ($v | str length) > 0 and (($v | str starts-with ' ') or ($v | str starts-with "\t")) {
        print -e ("ERROR: (" + $f + ":" + ($n | into string) + ") " + $ERROR_VALUE_LEADING_WHITESPACE)
        $errors += 1
        continue
      }
      let first_ok = (not ($k | str substring 0..<1 | parse --regex "[A-Za-z_]" | is-empty))
      let rest_ok = (($k | str substring 1.. | split chars | all {|c| not ($c | parse --regex "[A-Za-z0-9_]" | is-empty) }) or ($k | str length) == 1)
      if not ($first_ok and $rest_ok) {
        print -e ("ERROR: (" + $f + ":" + ($n | into string) + ") " + $ERROR_KEY_INVALID + " '" + $k + "'")
        $errors += 1
        continue
      }
      if ($k | str upcase) != $k {
        print -e ("WARNING: (" + $f + ":" + ($n | into string) + ") key '" + $k + "' " + $WARN_KEY_NOT_UPPERCASE)
        $warnings += 1
      }

      if ($v | str length) == 0 { continue }

      let c = ($v | str substring 0..<1)

      if $c == '"' {
        let rest = ($v | str substring 1..)
        let pos = ($rest | str index-of '"')
        if $pos == -1 {
          print -e ("ERROR: (" + $f + ":" + ($n | into string) + ") " + $ERROR_DOUBLE_QUOTE_UNTERMINATED)
          $errors += 1
          continue
        }
        let after = ($rest | str substring ($pos + 1)..)
        if ($after | str length) > 0 {
          print -e ("ERROR: (" + $f + ":" + ($n | into string) + ") " + $ERROR_TRAILING_CONTENT)
          $errors += 1
          continue
        }
      } else if $c == "'" {
        let rest = ($v | str substring 1..)
        let pos = ($rest | str index-of "'")
        if $pos == -1 {
          print -e ("ERROR: (" + $f + ":" + ($n | into string) + ") " + $ERROR_SINGLE_QUOTE_UNTERMINATED)
          $errors += 1
          continue
        }
        let after = ($rest | str substring ($pos + 1)..)
        if ($after | str length) > 0 {
          print -e ("ERROR: (" + $f + ":" + ($n | into string) + ") " + $ERROR_TRAILING_CONTENT)
          $errors += 1
          continue
        }
      } else {
        let has_bad = ($v | str contains ' ') or ($v | str contains "'") or ($v | str contains '"') or ($v | str contains "\u{5c}")  # \u{5c} = backslash; nu has no unambiguous backslash literal
        if ($v | str length) > 0 and $has_bad {
          print -e ("ERROR: (" + $f + ":" + ($n | into string) + ") " + $ERROR_VALUE_INVALID_CHAR)
          $errors += 1
          continue
        }
      }
    }
  }

  print -e $"($checked) checked, ($errors) errors, ($warnings) warnings"
  if $errors > 0 { exit 1 }
}
