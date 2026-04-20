// main.go — validate/normalize env files
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
)

type parser struct {
	format  string
	action  string
	bom     string
	crlf    string
	nul     string
	cont    string
	checked int
	errors  int
	envMap  map[string][]byte
}

var bomBytes = []byte{0xEF, 0xBB, 0xBF}

func fatal(code, detail string) {
	fmt.Fprintf(os.Stderr, "%s: %s\n", code, detail)
	os.Exit(1)
}

func (p *parser) diag(path string, lineno int, code string) {
	fmt.Fprintf(os.Stderr, "%s: %s:%d\n", code, path, lineno)
	p.errors++
}

func (p *parser) fdiag(path, code string) {
	fmt.Fprintf(os.Stderr, "%s: %s\n", code, path)
	p.errors++
}

func splitLines(buf []byte) [][]byte {
	lines := bytes.Split(buf, []byte{'\n'})
	if len(lines) > 0 && len(lines[len(lines)-1]) == 0 {
		lines = lines[:len(lines)-1]
	}
	return lines
}

func isContinuation(line []byte) bool {
	n := 0
	for i := len(line) - 1; i >= 0 && line[i] == '\\'; i-- {
		n++
	}
	return n%2 == 1
}

func validShellKey(key []byte) bool {
	if len(key) == 0 {
		return false
	}
	first := key[0]
	if !((first >= 'A' && first <= 'Z') || (first >= 'a' && first <= 'z') || first == '_') {
		return false
	}
	for _, c := range key[1:] {
		if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {
			return false
		}
	}
	return true
}

func (p *parser) unquoteShellValue(path string, lineno int, value []byte) ([]byte, bool) {
	if len(value) == 0 {
		return value, true
	}
	c := value[0]
	if c == '"' || c == '\'' {
		rest := value[1:]
		pos := bytes.IndexByte(rest, c)
		if pos == -1 {
			if c == '"' {
				p.diag(path, lineno, "LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED")
			} else {
				p.diag(path, lineno, "LINE_ERROR_SINGLE_QUOTE_UNTERMINATED")
			}
			return nil, false
		}
		if len(rest[pos+1:]) != 0 {
			p.diag(path, lineno, "LINE_ERROR_TRAILING_CONTENT")
			return nil, false
		}
		return rest[:pos], true
	}
	for _, c := range value {
		if c == ' ' || c == '\t' || c == '\'' || c == '"' || c == '\\' {
			p.diag(path, lineno, "LINE_ERROR_VALUE_INVALID_CHAR")
			return nil, false
		}
	}
	return value, true
}

func (p *parser) seedEnv() {
	p.envMap = make(map[string][]byte, len(os.Environ()))
	for _, entry := range os.Environ() {
		eq := strings.IndexByte(entry, '=')
		if eq < 0 {
			continue
		}
		k := entry[:eq]
		if strings.HasPrefix(k, "ENVFILE_") {
			continue
		}
		p.envMap[k] = []byte(entry[eq+1:])
	}
}

func isNameStart(c byte) bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'
}

func isNameContinue(c byte) bool {
	return isNameStart(c) || (c >= '0' && c <= '9')
}

func (p *parser) substValue(path string, lineno int, value []byte) []byte {
	var out bytes.Buffer
	i := 0
	for i < len(value) {
		pos := bytes.IndexByte(value[i:], '$')
		if pos == -1 {
			out.Write(value[i:])
			break
		}
		pos += i
		out.Write(value[i:pos])

		if pos+1 >= len(value) {
			out.WriteByte('$')
			break
		}

		rest := value[pos+1:]
		var name []byte
		if rest[0] == '{' {
			close := bytes.IndexByte(rest[1:], '}')
			if close == -1 {
				out.WriteByte('$')
				out.Write(rest)
				break
			}
			name = rest[1 : close+1]
			i = pos + close + 3
		} else {
			if !isNameStart(rest[0]) {
				out.WriteByte('$')
				i = pos + 1
				continue
			}
			j := 1
			for j < len(rest) && isNameContinue(rest[j]) {
				j++
			}
			name = rest[:j]
			i = pos + 1 + j
		}

		if resolved, ok := p.envMap[string(name)]; ok {
			out.Write(resolved)
		} else {
			fmt.Fprintf(os.Stderr, "LINE_ERROR_UNBOUND_REF (%s): %s:%d\n", string(name), path, lineno)
			p.errors++
		}
	}
	return out.Bytes()
}

func (p *parser) handleRecord(path string, lineno int, key, rawValue, value []byte) {
	if p.action == "dump" {
		fmt.Printf("%s=%s\n", key, value)
		return
	}
	if p.action == "validate" || p.action == "normalize" {
		return
	}

	resolved := value
	if p.format == "native" || !(len(rawValue) > 0 && rawValue[0] == '\'') {
		resolved = p.substValue(path, lineno, resolved)
	}
	p.envMap[string(key)] = append([]byte(nil), resolved...)

	if p.action == "delta" {
		fmt.Printf("%s=%s\n", key, resolved)
	}
}

func isBlankSpacesTabs(line []byte) bool {
	for _, c := range line {
		if c != ' ' && c != '\t' {
			return false
		}
	}
	return true
}

type procLine struct {
	line   []byte
	lineno int
}

func (p *parser) processFile(path string, fileBytes []byte) {
	if p.nul == "reject" && bytes.IndexByte(fileBytes, 0x00) != -1 {
		p.fdiag(path, "FILE_ERROR_NUL")
		return
	}

	lines := splitLines(fileBytes)

	if len(lines) > 0 && bytes.HasPrefix(lines[0], bomBytes) {
		switch p.bom {
		case "reject":
			p.fdiag(path, "FILE_ERROR_BOM")
			return
		case "strip":
			lines[0] = lines[0][3:]
		}
	}

	if p.crlf == "strip" {
		allCRLF := len(lines) > 0
		for _, line := range lines {
			if len(line) == 0 || line[len(line)-1] != '\r' {
				allCRLF = false
				break
			}
		}
		if allCRLF {
			for i := range lines {
				lines[i] = lines[i][:len(lines[i])-1]
			}
		}
	}

	var proc []procLine
	if p.cont == "accept" {
		i := 0
		for i < len(lines) {
			line := lines[i]
			lineno := i + 1
			i++
			for isContinuation(line) && i < len(lines) {
				next := lines[i]
				joined := make([]byte, 0, len(line)-1+len(next))
				joined = append(joined, line[:len(line)-1]...)
				joined = append(joined, next...)
				line = joined
				lineno = i + 1
				i++
			}
			proc = append(proc, procLine{line: line, lineno: lineno})
		}
	} else {
		proc = make([]procLine, 0, len(lines))
		for i, line := range lines {
			proc = append(proc, procLine{line: line, lineno: i + 1})
		}
	}

	for _, pl := range proc {
		line := pl.line
		lineno := pl.lineno
		trimmed := line
		if len(trimmed) > 0 && trimmed[len(trimmed)-1] == '\r' {
			trimmed = trimmed[:len(trimmed)-1]
		}
		if isBlankSpacesTabs(trimmed) {
			continue
		}
		if len(trimmed) > 0 && trimmed[0] == '#' {
			continue
		}

		p.checked++
		eq := bytes.IndexByte(line, '=')
		if eq == -1 {
			p.diag(path, lineno, "LINE_ERROR_NO_EQUALS")
			continue
		}
		rawKey := line[:eq]
		rawValue := line[eq+1:]

		if p.action == "normalize" {
			fmt.Printf("%s=%s\n", rawKey, rawValue)
			continue
		}

		work := line
		if p.format != "native" {
			work = trimmed
		}
		eq2 := bytes.IndexByte(work, '=')
		if eq2 == -1 {
			p.diag(path, lineno, "LINE_ERROR_NO_EQUALS")
			continue
		}
		key := work[:eq2]
		value := work[eq2+1:]

		if p.format == "native" {
			if len(key) == 0 {
				p.diag(path, lineno, "LINE_ERROR_EMPTY_KEY")
				continue
			}
			p.handleRecord(path, lineno, key, rawValue, value)
			continue
		}

		if len(key) > 0 && (key[0] == ' ' || key[0] == '\t') {
			p.diag(path, lineno, "LINE_ERROR_KEY_LEADING_WHITESPACE")
			continue
		}
		if len(key) > 0 && (key[len(key)-1] == ' ' || key[len(key)-1] == '\t') {
			p.diag(path, lineno, "LINE_ERROR_KEY_TRAILING_WHITESPACE")
			continue
		}
		if len(value) > 0 && (value[0] == ' ' || value[0] == '\t') {
			p.diag(path, lineno, "LINE_ERROR_VALUE_LEADING_WHITESPACE")
			continue
		}
		if len(key) == 0 {
			p.diag(path, lineno, "LINE_ERROR_EMPTY_KEY")
			continue
		}
		if !validShellKey(key) {
			p.diag(path, lineno, "LINE_ERROR_KEY_INVALID")
			continue
		}

		unquoted, ok := p.unquoteShellValue(path, lineno, value)
		if !ok {
			continue
		}
		p.handleRecord(path, lineno, key, rawValue, unquoted)
	}
}

func readPath(path string) ([]byte, error) {
	if path == "-" {
		return io.ReadAll(os.Stdin)
	}
	return os.ReadFile(path)
}

func main() {
	format := os.Getenv("ENVFILE_FORMAT")
	if format == "" {
		format = "shell"
	}
	action := os.Getenv("ENVFILE_ACTION")
	if action == "" {
		action = "validate"
	}

	bom := os.Getenv("ENVFILE_BOM")
	if bom == "" {
		if format == "native" {
			bom = "literal"
		} else {
			bom = "strip"
		}
	}
	crlf := os.Getenv("ENVFILE_CRLF")
	if crlf == "" {
		crlf = "ignore"
	}
	nul := os.Getenv("ENVFILE_NUL")
	if nul == "" {
		nul = "reject"
	}
	cont := os.Getenv("ENVFILE_BACKSLASH_CONTINUATION")
	if cont == "" {
		cont = "ignore"
	}

	switch bom {
	case "literal", "strip", "reject":
	default:
		fatal("FATAL_ERROR_BAD_ENVFILE_VALUE", "ENVFILE_BOM="+bom)
	}
	if format == "native" && bom != "literal" {
		fatal("FATAL_ERROR_UNSUPPORTED", "format=native ENVFILE_BOM="+bom)
	}

	p := &parser{
		format: format,
		action: action,
		bom:    bom,
		crlf:   crlf,
		nul:    nul,
		cont:   cont,
	}

	files := os.Args[1:]
	if len(files) == 0 {
		files = []string{"-"}
	}

	if action == "delta" || action == "apply" {
		p.seedEnv()
	}

	for _, path := range files {
		data, err := readPath(path)
		if err != nil {
			p.fdiag(path, "FILE_ERROR_FILE_UNREADABLE")
			continue
		}
		p.processFile(path, data)
	}

	if action == "apply" {
		keys := make([]string, 0, len(p.envMap))
		for k := range p.envMap {
			if strings.HasPrefix(k, "ENVFILE_") {
				continue
			}
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			fmt.Printf("%s=%s\n", k, p.envMap[k])
		}
	}

	fmt.Fprintf(os.Stderr, "%d checked, %d errors\n", p.checked, p.errors)
	if p.errors > 0 {
		os.Exit(1)
	}
}
