// main.rs — validate/normalize env files (see README.md)

use std::fs::File;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::process;

const ERROR_NO_EQUALS: &str = "ERROR_NO_EQUALS";
const ERROR_EMPTY_KEY: &str = "ERROR_EMPTY_KEY";
const ERROR_KEY_LEADING_WHITESPACE: &str = "ERROR_KEY_LEADING_WHITESPACE";
const ERROR_KEY_TRAILING_WHITESPACE: &str = "ERROR_KEY_TRAILING_WHITESPACE";
const ERROR_VALUE_LEADING_WHITESPACE: &str = "ERROR_VALUE_LEADING_WHITESPACE";
const ERROR_KEY_INVALID: &str = "ERROR_KEY_INVALID";
const ERROR_DOUBLE_QUOTE_UNTERMINATED: &str = "ERROR_DOUBLE_QUOTE_UNTERMINATED";
const ERROR_SINGLE_QUOTE_UNTERMINATED: &str = "ERROR_SINGLE_QUOTE_UNTERMINATED";
const ERROR_TRAILING_CONTENT: &str = "ERROR_TRAILING_CONTENT";
const ERROR_VALUE_INVALID_CHAR: &str = "ERROR_VALUE_INVALID_CHAR";
const ERROR_LINE_TOO_LONG: &str = "ERROR_LINE_TOO_LONG";

// --- character classifiers ---

fn is_native_key_start(b: u8) -> bool {
    matches!(b, b'A'..=b'Z' | b'_')
}
fn is_native_key_rest(b: u8) -> bool {
    matches!(b, b'A'..=b'Z' | b'0'..=b'9' | b'_')
}
fn is_strict_key_start(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_'
}
fn is_strict_key_rest(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}
fn is_bad_val(b: u8) -> bool {
    b.is_ascii_whitespace() || matches!(b, b'\'' | b'"' | b'\\')
}

fn valid_native_key(k: &[u8]) -> bool {
    match k.split_first() {
        Some((&f, rest)) => is_native_key_start(f) && rest.iter().all(|&b| is_native_key_rest(b)),
        None => false,
    }
}

fn valid_strict_key(k: &str) -> bool {
    let mut chars = k.bytes();
    chars.next().map_or(false, is_strict_key_start) && chars.all(is_strict_key_rest)
}

// --- counts ---

#[derive(Default)]
struct Counts {
    checked: u32,
    errors: u32,
}

// --- native core: slurp and scan ---

fn native_record(
    line: &[u8],
    tag: &str,
    n: u32,
    diag: &mut impl Write,
    norm: &mut impl Write,
    normalize: bool,
) -> (u32, u32) {
    if line.iter().any(|&b| b == 0) {
        writeln!(diag, "{ERROR_VALUE_INVALID_CHAR}: {tag}:{n}").ok();
        return (1, 1);
    }
    if line.is_empty() || line.iter().all(|b| b.is_ascii_whitespace()) || line[0] == b'#' {
        return (0, 0);
    }
    let Some(eq) = line.iter().position(|&b| b == b'=') else {
        writeln!(diag, "{ERROR_NO_EQUALS}: {tag}:{n}").ok();
        return (1, 1);
    };
    let k = &line[..eq];
    let v = &line[eq + 1..];

    if k.is_empty() {
        writeln!(diag, "{ERROR_EMPTY_KEY}: {tag}:{n}").ok();
        return (1, 1);
    }
    if !valid_native_key(k) {
        writeln!(diag, "{ERROR_KEY_INVALID}: {tag}:{n}").ok();
        return (1, 1);
    }
    if normalize {
        norm.write_all(k).ok();
        norm.write_all(b"=").ok();
        norm.write_all(v).ok();
        norm.write_all(b"\n").ok();
    }
    (1, 0)
}

fn native_scan(
    buf: &[u8],
    tag: &str,
    n: &mut u32,
    diag: &mut impl Write,
    norm: &mut impl Write,
    normalize: bool,
    counts: &mut Counts,
) {
    let mut pos = 0;
    loop {
        let nl = buf[pos..].iter().position(|&b| b == b'\n');
        let end = nl.map_or(buf.len(), |i| pos + i);
        if end > pos || nl.is_some() {
            *n += 1;
            let (chk, err) = native_record(&buf[pos..end], tag, *n, diag, norm, normalize);
            counts.checked += chk;
            counts.errors += err;
        }
        match nl {
            None => break,
            Some(i) => pos += i + 1,
        }
    }
}

fn open_native(path: &str) -> io::Result<Box<dyn Read>> {
    if path == "-" {
        Ok(Box::new(io::stdin()))
    } else {
        Ok(Box::new(File::open(path)?))
    }
}

fn lint_native(
    path: &str,
    diag: &mut impl Write,
    norm: &mut impl Write,
    normalize: bool,
    counts: &mut Counts,
) {
    let mut f = match open_native(path) {
        Ok(f) => f,
        Err(e) => {
            writeln!(diag, "lint: {path}: {e}").ok();
            counts.errors += 1;
            return;
        }
    };

    let mut read_buf = [0u8; 4096];
    let mut buf = [0u8; 65536];
    let mut tail: usize = 0;
    let mut n: u32 = 0;

    loop {
        let nr = match f.read(&mut read_buf) {
            Ok(n) => n,
            Err(e) => {
                writeln!(diag, "lint: {path}: {e}").ok();
                counts.errors += 1;
                return;
            }
        };

        if tail + nr > buf.len() {
            writeln!(diag, "{ERROR_LINE_TOO_LONG}: {path}").ok();
            counts.errors += 1;
            return;
        }
        buf[tail..tail + nr].copy_from_slice(&read_buf[..nr]);
        let filled = tail + nr;
        let eof = nr == 0;

        if filled == 0 {
            break;
        }

        if eof {
            native_scan(&buf[..filled], path, &mut n, diag, norm, normalize, counts);
            break;
        }

        let last_nl = buf[..filled].iter().rposition(|&b| b == b'\n');
        let Some(last_nl) = last_nl else {
            if filled == buf.len() {
                writeln!(diag, "{ERROR_LINE_TOO_LONG}: {path}").ok();
                counts.errors += 1;
                return;
            }
            tail = filled;
            continue;
        };

        let complete = last_nl + 1;
        native_scan(
            &buf[..complete],
            path,
            &mut n,
            diag,
            norm,
            normalize,
            counts,
        );

        tail = filled - complete;
        buf.copy_within(complete..filled, 0);
    }
}

// --- strict core: line-oriented ---

struct LineResult<'a> {
    diag: Option<&'static str>,
    fatal: bool,
    val: &'a str,
}

fn strict_line(line: &str) -> LineResult<'_> {
    if line.as_bytes().iter().any(|&b| b == 0) {
        return LineResult {
            diag: Some(ERROR_VALUE_INVALID_CHAR),
            fatal: true,
            val: "",
        };
    }
    let Some(eq) = line.find('=') else {
        return LineResult {
            diag: Some(ERROR_NO_EQUALS),
            fatal: true,
            val: "",
        };
    };
    let k = &line[..eq];
    let v = &line[eq + 1..];

    if k.starts_with(|c: char| c.is_ascii_whitespace()) {
        return LineResult {
            diag: Some(ERROR_KEY_LEADING_WHITESPACE),
            fatal: true,
            val: "",
        };
    }
    if k.ends_with(|c: char| c.is_ascii_whitespace()) {
        return LineResult {
            diag: Some(ERROR_KEY_TRAILING_WHITESPACE),
            fatal: true,
            val: "",
        };
    }
    if v.starts_with(|c: char| c.is_ascii_whitespace()) {
        return LineResult {
            diag: Some(ERROR_VALUE_LEADING_WHITESPACE),
            fatal: true,
            val: "",
        };
    }
    if !valid_strict_key(k) {
        return LineResult {
            diag: Some(ERROR_KEY_INVALID),
            fatal: true,
            val: "",
        };
    }

    let val = if v.is_empty() {
        v
    } else {
        let q = v.as_bytes()[0];
        if q == b'"' || q == b'\'' {
            let rest = &v[1..];
            let close = rest.find(q as char).map(|i| (i, &rest[i + 1..]));
            match close {
                None => {
                    return LineResult {
                        diag: Some(if q == b'"' {
                            ERROR_DOUBLE_QUOTE_UNTERMINATED
                        } else {
                            ERROR_SINGLE_QUOTE_UNTERMINATED
                        }),
                        fatal: true,
                        val: "",
                    }
                }
                Some((_, tail)) if !tail.is_empty() => {
                    return LineResult {
                        diag: Some(ERROR_TRAILING_CONTENT),
                        fatal: true,
                        val: "",
                    }
                }
                Some((pos, _)) => &rest[..pos],
            }
        } else {
            if v.bytes().any(is_bad_val) {
                return LineResult {
                    diag: Some(ERROR_VALUE_INVALID_CHAR),
                    fatal: true,
                    val: "",
                };
            }
            v
        }
    };

    LineResult {
        diag: None,
        fatal: false,
        val,
    }
}

fn lint_strict(
    path: &str,
    diag: &mut impl Write,
    norm: &mut impl Write,
    normalize: bool,
    counts: &mut Counts,
) {
    let reader: Box<dyn BufRead> = if path == "-" {
        Box::new(BufReader::new(io::stdin()))
    } else {
        match File::open(path) {
            Ok(f) => Box::new(BufReader::new(f)),
            Err(e) => {
                writeln!(diag, "lint: {path}: {e}").ok();
                counts.errors += 1;
                return;
            }
        }
    };

    for (idx, result) in reader.lines().enumerate() {
        let n = idx as u32 + 1;
        let raw = match result {
            Ok(s) => s,
            Err(e) => {
                writeln!(diag, "lint: {path}: {e}").ok();
                counts.errors += 1;
                return;
            }
        };
        let line = raw.trim_end_matches('\r');
        if line.as_bytes().iter().any(|&b| b == 0) {
            writeln!(diag, "{ERROR_VALUE_INVALID_CHAR}: {path}:{n}").ok();
            counts.checked += 1;
            counts.errors += 1;
            continue;
        }
        if line.bytes().all(|b| b.is_ascii_whitespace()) {
            continue;
        }
        if line.starts_with('#') {
            continue;
        }
        counts.checked += 1;

        let eq = line.find('=').unwrap_or(0);
        let k = &line[..eq];
        let r = strict_line(line);
        if let Some(code) = r.diag {
            writeln!(diag, "{code}: {path}:{n}").ok();
            if r.fatal {
                counts.errors += 1;
                continue;
            }
        }
        if normalize {
            writeln!(norm, "{k}={}", r.val).ok();
        }
    }
}

// --- main ---

fn main() {
    let format = std::env::var("ENVFILE_FORMAT").unwrap_or_else(|_| "strict".into());
    let action = std::env::var("ENVFILE_ACTION").unwrap_or_else(|_| "validate".into());
    let native = format == "native";
    let normalize = action == "normalize";

    let stderr = io::stderr();
    let stdout = io::stdout();
    let mut diag = io::BufWriter::new(stderr.lock());
    let mut norm = io::BufWriter::new(stdout.lock());

    let args: Vec<String> = std::env::args().collect();
    let files: &[String] = if args.len() > 1 { &args[1..] } else { &[] };
    let default = ["-".to_string()];
    let files = if files.is_empty() {
        &default[..]
    } else {
        files
    };

    let mut total = Counts::default();
    for path in files {
        let mut c = Counts::default();
        if native {
            lint_native(path, &mut diag, &mut norm, normalize, &mut c);
        } else {
            lint_strict(path, &mut diag, &mut norm, normalize, &mut c);
        }
        total.checked += c.checked;
        total.errors += c.errors;
    }

    writeln!(diag, "{} checked, {} errors", total.checked, total.errors).ok();
    norm.flush().ok();
    diag.flush().ok();

    if total.errors > 0 {
        process::exit(1);
    }
}
