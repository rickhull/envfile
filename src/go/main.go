// main.go — validate/normalize env files (see README.md)
package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"strings"
)

const (
	errorNoEquals                = "ERROR_NO_EQUALS"
	errorEmptyKey                = "ERROR_EMPTY_KEY"
	errorKeyLeadingWhitespace    = "ERROR_KEY_LEADING_WHITESPACE"
	errorKeyTrailingWhitespace   = "ERROR_KEY_TRAILING_WHITESPACE"
	errorValueLeadingWhitespace  = "ERROR_VALUE_LEADING_WHITESPACE"
	errorKeyInvalid              = "ERROR_KEY_INVALID"
	errorDoubleQuoteUnterminated = "ERROR_DOUBLE_QUOTE_UNTERMINATED"
	errorSingleQuoteUnterminated = "ERROR_SINGLE_QUOTE_UNTERMINATED"
	errorTrailingContent         = "ERROR_TRAILING_CONTENT"
	errorValueInvalidChar        = "ERROR_VALUE_INVALID_CHAR"
)

func validNativeKey(s string) bool {
	if len(s) == 0 {
		return false
	}
	b := s[0]
	if !((b >= 'A' && b <= 'Z') || b == '_') {
		return false
	}
	for i := 1; i < len(s); i++ {
		b = s[i]
		if !((b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_') {
			return false
		}
	}
	return true
}

func validStrictKey(s string) bool {
	if len(s) == 0 {
		return false
	}
	b := s[0]
	if !((b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || b == '_') {
		return false
	}
	for i := 1; i < len(s); i++ {
		b = s[i]
		if !((b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '_') {
			return false
		}
	}
	return true
}

func hasBadValChar(s string) bool {
	for i := 0; i < len(s); i++ {
		b := s[i]
		if b == ' ' || b == '\t' || b == '\'' || b == '"' || b == '\\' {
			return true
		}
	}
	return false
}

func scanLinesNOnly(data []byte, atEOF bool) (advance int, token []byte, err error) {
	if atEOF && len(data) == 0 {
		return 0, nil, nil
	}
	if i := bytes.IndexByte(data, '\n'); i >= 0 {
		return i + 1, data[0:i], nil
	}
	if atEOF {
		return len(data), data, nil
	}
	return 0, nil, nil
}

type state struct {
	path    string
	norm    *bytes.Buffer
	diag    *bytes.Buffer
	checked int
	errors  int
}

func (s *state) diag_(msg, path string, n int) {
	fmt.Fprintf(s.diag, "%s: %s:%d\n", msg, path, n)
	s.errors++
}

func (s *state) nativeLine(n int, line string) {
	eq := strings.IndexByte(line, '=')
	if eq == -1 {
		s.diag_(errorNoEquals, s.path, n)
		return
	}
	k, v := line[:eq], line[eq+1:]
	if len(k) == 0 {
		s.diag_(errorEmptyKey, s.path, n)
		return
	}
	if !validNativeKey(k) {
		s.diag_(errorKeyInvalid, s.path, n)
		return
	}
	if s.norm != nil {
		fmt.Fprintf(s.norm, "%s=%s\n", k, v)
	}
}

func (s *state) strictLine(n int, line string) {
	eq := strings.IndexByte(line, '=')
	if eq == -1 {
		s.diag_(errorNoEquals, s.path, n)
		return
	}
	k, v := line[:eq], line[eq+1:]

	if len(k) > 0 && (k[0] == ' ' || k[0] == '\t') {
		s.diag_(errorKeyLeadingWhitespace, s.path, n)
		return
	}
	if len(k) > 0 && (k[len(k)-1] == ' ' || k[len(k)-1] == '\t') {
		s.diag_(errorKeyTrailingWhitespace, s.path, n)
		return
	}
	if len(v) > 0 && (v[0] == ' ' || v[0] == '\t') {
		s.diag_(errorValueLeadingWhitespace, s.path, n)
		return
	}
	if !validStrictKey(k) {
		s.diag_(errorKeyInvalid, s.path, n)
		return
	}
	value := v
	if len(v) > 0 {
		switch v[0] {
		case '"', '\'':
			q := v[0]
			rest := v[1:]
			pos := strings.IndexByte(rest, q)
			if pos == -1 {
				if q == '"' {
					s.diag_(errorDoubleQuoteUnterminated, s.path, n)
				} else {
					s.diag_(errorSingleQuoteUnterminated, s.path, n)
				}
				return
			}
			if rest[pos+1:] != "" {
				s.diag_(errorTrailingContent, s.path, n)
				return
			}
			value = rest[:pos]
		default:
			if hasBadValChar(v) {
				s.diag_(errorValueInvalidChar, s.path, n)
				return
			}
		}
	}

	if s.norm != nil {
		fmt.Fprintf(s.norm, "%s=%s\n", k, value)
	}
}

func lintNative(path string, f *os.File, st *state) {
	scanner := bufio.NewScanner(f)
	scanner.Split(scanLinesNOnly)
	n := 0
	for scanner.Scan() {
		n++
		line := scanner.Text()
		if strings.IndexByte(line, 0) != -1 {
			st.checked++
			st.diag_(errorValueInvalidChar, path, n)
			continue
		}
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "#") {
			continue
		}
		st.checked++
		st.nativeLine(n, line)
	}
}

func lintStrict(path string, f *os.File, st *state) {
	scanner := bufio.NewScanner(f)
	n := 0
	for scanner.Scan() {
		n++
		line := strings.TrimRight(scanner.Text(), "\r")
		if strings.IndexByte(line, 0) != -1 {
			st.checked++
			st.diag_(errorValueInvalidChar, path, n)
			continue
		}
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "#") {
			continue
		}
		st.checked++
		st.strictLine(n, line)
	}
}

func openFile(path string) (*os.File, error) {
	if path == "-" {
		return os.Stdin, nil
	}
	return os.Open(path)
}

func main() {
	format := os.Getenv("ENVFILE_FORMAT")
	if format == "" {
		format = "strict"
	}
	action := os.Getenv("ENVFILE_ACTION")
	if action == "" {
		action = "validate"
	}

	files := os.Args[1:]
	if len(files) == 0 {
		files = []string{"-"}
	}

	var norm *bytes.Buffer
	if action == "normalize" {
		norm = &bytes.Buffer{}
	}
	diag := &bytes.Buffer{}

	var total state
	total.norm = norm
	total.diag = diag

	for _, path := range files {
		f, err := openFile(path)
		if err != nil {
			fmt.Fprintf(diag, "lint: %v\n", err)
			total.errors++
			continue
		}
		st := &state{path: path, norm: norm, diag: diag}
		if format == "native" {
			lintNative(path, f, st)
		} else {
			lintStrict(path, f, st)
		}
		if path != "-" {
			f.Close()
		}
		total.checked += st.checked
		total.errors += st.errors
	}

	fmt.Fprintf(diag, "%d checked, %d errors\n",
		total.checked, total.errors)

	if norm != nil {
		os.Stdout.Write(norm.Bytes())
	}
	os.Stderr.Write(diag.Bytes())

	if total.errors > 0 {
		os.Exit(1)
	}
}
