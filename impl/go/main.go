// lint.go — validate env files (see README.md)
package main

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strings"
)

const (
	errorNoEquals               = "missing assignment (=)"
	errorKeyLeadingWhitespace   = "leading whitespace before key"
	errorKeyTrailingWhitespace  = "whitespace before ="
	errorValueLeadingWhitespace = "whitespace after ="
	errorKeyInvalid             = "invalid key"
	errorDoubleQuoteUnterminated = "unterminated double quote"
	errorSingleQuoteUnterminated = "unterminated single quote"
	errorTrailingContent        = "trailing content after closing quote"
	errorValueInvalidChar       = "value contains whitespace, quote, or backslash"
	warnKeyNotUppercase         = "is not UPPERCASE (preferred)"
)

var keyRE = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
var badValRE = regexp.MustCompile(`[\s'"\\]`)

type counts struct {
	checked, errors, warnings int
}

func lintFile(path string) counts {
	f, err := os.Open(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "lint: %v\n", err)
		return counts{errors: 1}
	}
	defer f.Close()

	var c counts
	emit := func(n int, msg string) {
		fmt.Fprintf(os.Stderr, "%s:%d: %s\n", path, n, msg)
		c.errors++
	}
	warn := func(n int, msg string) {
		fmt.Fprintf(os.Stderr, "%s:%d: %s\n", path, n, msg)
		c.warnings++
	}

	scanner := bufio.NewScanner(f)
	n := 0
	for scanner.Scan() {
		n++
		line := strings.TrimRight(scanner.Text(), "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		if strings.HasPrefix(line, "#") {
			continue
		}
		c.checked++

		eq := strings.IndexByte(line, '=')
		if eq == -1 {
			emit(n, errorNoEquals)
			continue
		}
		k, v := line[:eq], line[eq+1:]

		if len(k) > 0 && (k[0] == ' ' || k[0] == '\t') {
			emit(n, errorKeyLeadingWhitespace)
			continue
		}
		if len(k) > 0 && (k[len(k)-1] == ' ' || k[len(k)-1] == '\t') {
			emit(n, errorKeyTrailingWhitespace)
			continue
		}
		if len(v) > 0 && (v[0] == ' ' || v[0] == '\t') {
			emit(n, errorValueLeadingWhitespace)
			continue
		}
		if !keyRE.MatchString(k) {
			emit(n, fmt.Sprintf("%s '%s'", errorKeyInvalid, k))
			continue
		}
		if k != strings.ToUpper(k) {
			warn(n, fmt.Sprintf("key '%s' %s", k, warnKeyNotUppercase))
		}

		if v == "" {
			continue
		}

		switch v[0] {
		case '"':
			rest := v[1:]
			pos := strings.IndexByte(rest, '"')
			if pos == -1 {
				emit(n, errorDoubleQuoteUnterminated)
				continue
			}
			if rest[pos+1:] != "" {
				emit(n, errorTrailingContent)
				continue
			}
		case '\'':
			rest := v[1:]
			pos := strings.IndexByte(rest, '\'')
			if pos == -1 {
				emit(n, errorSingleQuoteUnterminated)
				continue
			}
			if rest[pos+1:] != "" {
				emit(n, errorTrailingContent)
				continue
			}
		default:
			if badValRE.MatchString(v) {
				emit(n, errorValueInvalidChar)
				continue
			}
		}
	}
	return c
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "lint: no files specified")
		os.Exit(1)
	}

	var total counts
	for _, path := range os.Args[1:] {
		c := lintFile(path)
		total.checked += c.checked
		total.errors += c.errors
		total.warnings += c.warnings
	}

	fmt.Fprintf(os.Stderr, "%d checked, %d errors, %d warnings\n",
		total.checked, total.errors, total.warnings)

	if total.errors > 0 {
		os.Exit(1)
	}
}
