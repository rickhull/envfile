// main.rs — validate/normalize env files

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::process;

struct Parser {
    format: String,
    action: String,
    bom: String,
    crlf: String,
    nul: String,
    cont: String,
    checked: u64,
    errors: u64,
    env_map: HashMap<Vec<u8>, Vec<u8>>,
}

const BOM_BYTES: &[u8] = b"\xEF\xBB\xBF";

fn fatal(code: &str, detail: &str) -> ! {
    eprintln!("{code}: {detail}");
    process::exit(1);
}

impl Parser {
    fn diag(&mut self, path: &str, lineno: usize, code: &str) {
        eprintln!("{code}: {path}:{lineno}");
        self.errors += 1;
    }

    fn fdiag(&mut self, path: &str, code: &str) {
        eprintln!("{code}: {path}");
        self.errors += 1;
    }

    fn seed_env(&mut self) {
        self.env_map.clear();
        for (k, v) in std::env::vars() {
            if k.starts_with("ENVFILE_") {
                continue;
            }
            self.env_map.insert(k.into_bytes(), v.into_bytes());
        }
    }

    fn unquote_shell_value(
        &mut self,
        path: &str,
        lineno: usize,
        value: &[u8],
    ) -> Option<Vec<u8>> {
        if value.is_empty() {
            return Some(Vec::new());
        }
        let c = value[0];
        if c == b'"' || c == b'\'' {
            let rest = &value[1..];
            if let Some(pos) = rest.iter().position(|&b| b == c) {
                if pos + 1 != rest.len() {
                    self.diag(path, lineno, "LINE_ERROR_TRAILING_CONTENT");
                    return None;
                }
                return Some(rest[..pos].to_vec());
            }
            if c == b'"' {
                self.diag(path, lineno, "LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED");
            } else {
                self.diag(path, lineno, "LINE_ERROR_SINGLE_QUOTE_UNTERMINATED");
            }
            return None;
        }
        if value
            .iter()
            .any(|&b| b == b' ' || b == b'\t' || b == b'\'' || b == b'"' || b == b'\\')
        {
            self.diag(path, lineno, "LINE_ERROR_VALUE_INVALID_CHAR");
            return None;
        }
        Some(value.to_vec())
    }

    fn subst_value(&mut self, path: &str, lineno: usize, value: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(value.len());
        let mut i = 0usize;
        while i < value.len() {
            let pos_rel = value[i..].iter().position(|&b| b == b'$');
            let Some(pos_rel) = pos_rel else {
                out.extend_from_slice(&value[i..]);
                break;
            };
            let pos = i + pos_rel;
            out.extend_from_slice(&value[i..pos]);
            if pos + 1 >= value.len() {
                out.push(b'$');
                break;
            }

            let rest = &value[pos + 1..];
            let name: &[u8];
            if rest[0] == b'{' {
                let close_rel = rest[1..].iter().position(|&b| b == b'}');
                let Some(close_rel) = close_rel else {
                    out.push(b'$');
                    out.extend_from_slice(rest);
                    break;
                };
                name = &rest[1..1 + close_rel];
                i = pos + close_rel + 3;
            } else {
                if !is_name_start(rest[0]) {
                    out.push(b'$');
                    i = pos + 1;
                    continue;
                }
                let mut j = 1usize;
                while j < rest.len() && is_name_continue(rest[j]) {
                    j += 1;
                }
                name = &rest[..j];
                i = pos + 1 + j;
            }

            if let Some(resolved) = self.env_map.get(name) {
                out.extend_from_slice(resolved);
            } else {
                eprintln!(
                    "LINE_ERROR_UNBOUND_REF ({}): {path}:{lineno}",
                    String::from_utf8_lossy(name)
                );
                self.errors += 1;
            }
        }
        out
    }

    fn handle_record(
        &mut self,
        out: &mut dyn Write,
        path: &str,
        lineno: usize,
        key: &[u8],
        raw_value: &[u8],
        value: &[u8],
    ) {
        if self.action == "dump" {
            write_kv(out, key, value);
            return;
        }
        if self.action == "validate" || self.action == "normalize" {
            return;
        }

        let resolved = if self.format == "native" || !raw_value.starts_with(b"'") {
            self.subst_value(path, lineno, value)
        } else {
            value.to_vec()
        };

        self.env_map.insert(key.to_vec(), resolved.clone());
        if self.action == "delta" {
            write_kv(out, key, &resolved);
        }
    }

    fn process_file(&mut self, out: &mut dyn Write, path: &str, file_bytes: &[u8]) {
        if self.nul == "reject" && file_bytes.contains(&0x00) {
            self.fdiag(path, "FILE_ERROR_NUL");
            return;
        }

        let mut lines = split_lines(file_bytes);

        if !lines.is_empty() && lines[0].starts_with(BOM_BYTES) {
            match self.bom.as_str() {
                "reject" => {
                    self.fdiag(path, "FILE_ERROR_BOM");
                    return;
                }
                "strip" => {
                    lines[0] = lines[0][3..].to_vec();
                }
                _ => {}
            }
        }

        if self.crlf == "strip" {
            let mut all_crlf = !lines.is_empty();
            for line in &lines {
                if line.last().copied() != Some(b'\r') {
                    all_crlf = false;
                    break;
                }
            }
            if all_crlf {
                for line in &mut lines {
                    line.pop();
                }
            }
        }

        let mut proc_lines: Vec<(Vec<u8>, usize)> = Vec::new();
        if self.cont == "accept" {
            let mut i = 0usize;
            while i < lines.len() {
                let mut line = lines[i].clone();
                let mut lineno = i + 1;
                i += 1;
                while is_continuation(&line) && i < lines.len() {
                    line.pop();
                    line.extend_from_slice(&lines[i]);
                    lineno = i + 1;
                    i += 1;
                }
                proc_lines.push((line, lineno));
            }
        } else {
            for (idx, line) in lines.into_iter().enumerate() {
                proc_lines.push((line, idx + 1));
            }
        }

        for (line, lineno) in proc_lines {
            let trimmed = if line.last().copied() == Some(b'\r') {
                &line[..line.len() - 1]
            } else {
                &line[..]
            };
            if is_blank_spaces_tabs(trimmed) {
                continue;
            }
            if trimmed.first().copied() == Some(b'#') {
                continue;
            }

            self.checked += 1;

            let Some(eq) = line.iter().position(|&b| b == b'=') else {
                self.diag(path, lineno, "LINE_ERROR_NO_EQUALS");
                continue;
            };
            let raw_key = &line[..eq];
            let raw_value = &line[eq + 1..];

            if self.action == "normalize" {
                write_kv(out, raw_key, raw_value);
                continue;
            }

            let work: &[u8] = if self.format == "native" { &line } else { trimmed };
            let Some(eq2) = work.iter().position(|&b| b == b'=') else {
                self.diag(path, lineno, "LINE_ERROR_NO_EQUALS");
                continue;
            };
            let key = &work[..eq2];
            let value = &work[eq2 + 1..];

            if self.format == "native" {
                if key.is_empty() {
                    self.diag(path, lineno, "LINE_ERROR_EMPTY_KEY");
                    continue;
                }
                self.handle_record(out, path, lineno, key, raw_value, value);
                continue;
            }

            if key.first().copied() == Some(b' ') || key.first().copied() == Some(b'\t') {
                self.diag(path, lineno, "LINE_ERROR_KEY_LEADING_WHITESPACE");
                continue;
            }
            if key.last().copied() == Some(b' ') || key.last().copied() == Some(b'\t') {
                self.diag(path, lineno, "LINE_ERROR_KEY_TRAILING_WHITESPACE");
                continue;
            }
            if value.first().copied() == Some(b' ') || value.first().copied() == Some(b'\t') {
                self.diag(path, lineno, "LINE_ERROR_VALUE_LEADING_WHITESPACE");
                continue;
            }
            if key.is_empty() {
                self.diag(path, lineno, "LINE_ERROR_EMPTY_KEY");
                continue;
            }
            if !valid_shell_key(key) {
                self.diag(path, lineno, "LINE_ERROR_KEY_INVALID");
                continue;
            }

            let Some(unquoted) = self.unquote_shell_value(path, lineno, value) else {
                continue;
            };
            self.handle_record(out, path, lineno, key, raw_value, &unquoted);
        }
    }
}

fn split_lines(buf: &[u8]) -> Vec<Vec<u8>> {
    let mut lines: Vec<Vec<u8>> = buf.split(|&b| b == b'\n').map(|s| s.to_vec()).collect();
    if matches!(lines.last(), Some(last) if last.is_empty()) {
        lines.pop();
    }
    lines
}

fn is_continuation(line: &[u8]) -> bool {
    let mut n = 0usize;
    for &b in line.iter().rev() {
        if b != b'\\' {
            break;
        }
        n += 1;
    }
    n % 2 == 1
}

fn is_blank_spaces_tabs(line: &[u8]) -> bool {
    line.iter().all(|&b| b == b' ' || b == b'\t')
}

fn valid_shell_key(key: &[u8]) -> bool {
    if key.is_empty() {
        return false;
    }
    let first = key[0];
    if !matches!(first, b'A'..=b'Z' | b'a'..=b'z' | b'_') {
        return false;
    }
    key[1..]
        .iter()
        .all(|&b| matches!(b, b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'_'))
}

fn is_name_start(c: u8) -> bool {
    matches!(c, b'A'..=b'Z' | b'a'..=b'z' | b'_')
}

fn is_name_continue(c: u8) -> bool {
    is_name_start(c) || c.is_ascii_digit()
}

fn read_path(path: &str) -> io::Result<Vec<u8>> {
    let mut buf = Vec::new();
    if path == "-" {
        io::stdin().read_to_end(&mut buf)?;
    } else {
        std::fs::File::open(path)?.read_to_end(&mut buf)?;
    }
    Ok(buf)
}

fn write_kv(out: &mut dyn Write, key: &[u8], value: &[u8]) {
    let _ = out.write_all(key);
    let _ = out.write_all(b"=");
    let _ = out.write_all(value);
    let _ = out.write_all(b"\n");
}

fn main() {
    let format = std::env::var("ENVFILE_FORMAT").unwrap_or_else(|_| "shell".to_string());
    let action = std::env::var("ENVFILE_ACTION").unwrap_or_else(|_| "validate".to_string());
    let bom = std::env::var("ENVFILE_BOM").unwrap_or_else(|_| {
        if format == "native" {
            "literal".to_string()
        } else {
            "strip".to_string()
        }
    });
    let crlf = std::env::var("ENVFILE_CRLF").unwrap_or_else(|_| "ignore".to_string());
    let nul = std::env::var("ENVFILE_NUL").unwrap_or_else(|_| "reject".to_string());
    let cont =
        std::env::var("ENVFILE_BACKSLASH_CONTINUATION").unwrap_or_else(|_| "ignore".to_string());

    match bom.as_str() {
        "literal" | "strip" | "reject" => {}
        _ => fatal("FATAL_ERROR_BAD_ENVFILE_VALUE", &format!("ENVFILE_BOM={bom}")),
    }
    if format == "native" && bom != "literal" {
        fatal(
            "FATAL_ERROR_UNSUPPORTED",
            &format!("format=native ENVFILE_BOM={bom}"),
        );
    }

    let mut parser = Parser {
        format,
        action,
        bom,
        crlf,
        nul,
        cont,
        checked: 0,
        errors: 0,
        env_map: HashMap::new(),
    };

    let mut files: Vec<String> = std::env::args().skip(1).collect();
    if files.is_empty() {
        files.push("-".to_string());
    }

    if parser.action == "delta" || parser.action == "apply" {
        parser.seed_env();
    }

    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());

    for path in files {
        match read_path(&path) {
            Ok(data) => parser.process_file(&mut out, &path, &data),
            Err(_) => parser.fdiag(&path, "FILE_ERROR_FILE_UNREADABLE"),
        }
    }

    if parser.action == "apply" {
        let mut keys: Vec<Vec<u8>> = parser
            .env_map
            .keys()
            .filter(|k| !k.starts_with(b"ENVFILE_"))
            .cloned()
            .collect();
        keys.sort();
        for key in keys {
            if let Some(value) = parser.env_map.get(&key) {
                write_kv(&mut out, &key, value);
            }
        }
    }

    let _ = out.flush();
    eprintln!("{} checked, {} errors", parser.checked, parser.errors);
    if parser.errors > 0 {
        process::exit(1);
    }
}
