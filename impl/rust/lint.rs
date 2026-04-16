// lint.rs — validate env files (see README.md)

use std::fs::File;
use std::io::{self, BufRead, BufReader, Write};
use std::process;

const ERROR_NO_EQUALS:                &str = "missing assignment (=)";
const ERROR_KEY_LEADING_WHITESPACE:   &str = "leading whitespace before key";
const ERROR_KEY_TRAILING_WHITESPACE:  &str = "whitespace before =";
const ERROR_VALUE_LEADING_WHITESPACE: &str = "whitespace after =";
const ERROR_KEY_INVALID:              &str = "invalid key";
const ERROR_DOUBLE_QUOTE_UNTERMINATED: &str = "unterminated double quote";
const ERROR_SINGLE_QUOTE_UNTERMINATED: &str = "unterminated single quote";
const ERROR_TRAILING_CONTENT:         &str = "trailing content after closing quote";
const ERROR_VALUE_INVALID_CHAR:       &str = "value contains whitespace, quote, or backslash";
const WARN_KEY_NOT_UPPERCASE:         &str = "is not UPPERCASE (preferred)";

#[derive(Default)]
struct Counts {
    checked:  u32,
    errors:   u32,
    warnings: u32,
}

fn is_key_start(c: char) -> bool { c.is_ascii_alphabetic() || c == '_' }
fn is_key_rest(c: char)  -> bool { c.is_ascii_alphanumeric() || c == '_' }
fn is_bad_val(c: char)   -> bool { c.is_ascii_whitespace() || c == '\'' || c == '"' || c == '\\' }

fn lint_file(path: &str, stderr: &mut impl Write) -> io::Result<Counts> {
    let file = match File::open(path) {
        Ok(f) => f,
        Err(e) => {
            writeln!(stderr, "lint: {path}: {e}")?;
            return Ok(Counts { errors: 1, ..Default::default() });
        }
    };

    let mut c = Counts::default();

    for (idx, result) in BufReader::new(file).lines().enumerate() {
        let n = idx + 1;
        let raw = result?;
        let line = raw.trim_end_matches('\r');

        if line.trim().is_empty() { continue; }
        if line.starts_with('#')  { continue; }
        c.checked += 1;

        let Some(eq) = line.find('=') else {
            writeln!(stderr, "{path}:{n}: {ERROR_NO_EQUALS}")?;
            c.errors += 1; continue;
        };

        let k = &line[..eq];
        let v = &line[eq + 1..];

        if k.starts_with(|c: char| c.is_ascii_whitespace()) {
            writeln!(stderr, "{path}:{n}: {ERROR_KEY_LEADING_WHITESPACE}")?;
            c.errors += 1; continue;
        }
        if k.ends_with(|c: char| c.is_ascii_whitespace()) {
            writeln!(stderr, "{path}:{n}: {ERROR_KEY_TRAILING_WHITESPACE}")?;
            c.errors += 1; continue;
        }
        if !v.is_empty() && v.starts_with(|c: char| c.is_ascii_whitespace()) {
            writeln!(stderr, "{path}:{n}: {ERROR_VALUE_LEADING_WHITESPACE}")?;
            c.errors += 1; continue;
        }

        let mut chars = k.chars();
        let key_ok = chars.next().map_or(false, is_key_start) && chars.all(is_key_rest);
        if !key_ok {
            writeln!(stderr, "{path}:{n}: {ERROR_KEY_INVALID} '{k}'")?;
            c.errors += 1; continue;
        }

        if k != k.to_uppercase() {
            writeln!(stderr, "{path}:{n}: key '{k}' {WARN_KEY_NOT_UPPERCASE}")?;
            c.warnings += 1;
        }

        if v.is_empty() { continue; }

        match v.chars().next().unwrap() {
            '"' => {
                let rest = &v[1..];
                match rest.find('"') {
                    None => { writeln!(stderr, "{path}:{n}: {ERROR_DOUBLE_QUOTE_UNTERMINATED}")?; c.errors += 1; continue; }
                    Some(pos) if !rest[pos + 1..].is_empty() => {
                        writeln!(stderr, "{path}:{n}: {ERROR_TRAILING_CONTENT}")?; c.errors += 1; continue;
                    }
                    _ => {}
                }
            }
            '\'' => {
                let rest = &v[1..];
                match rest.find('\'') {
                    None => { writeln!(stderr, "{path}:{n}: {ERROR_SINGLE_QUOTE_UNTERMINATED}")?; c.errors += 1; continue; }
                    Some(pos) if !rest[pos + 1..].is_empty() => {
                        writeln!(stderr, "{path}:{n}: {ERROR_TRAILING_CONTENT}")?; c.errors += 1; continue;
                    }
                    _ => {}
                }
            }
            _ => {
                if v.contains(is_bad_val) {
                    writeln!(stderr, "{path}:{n}: {ERROR_VALUE_INVALID_CHAR}")?;
                    c.errors += 1; continue;
                }
            }
        }
    }

    Ok(c)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("lint: no files specified");
        process::exit(1);
    }

    let stderr = io::stderr();
    let mut out = io::BufWriter::new(stderr.lock());
    let mut total = Counts::default();

    for path in &args[1..] {
        match lint_file(path, &mut out) {
            Ok(c) => {
                total.checked  += c.checked;
                total.errors   += c.errors;
                total.warnings += c.warnings;
            }
            Err(e) => {
                writeln!(out, "lint: {path}: {e}").ok();
                total.errors += 1;
            }
        }
    }

    writeln!(out, "{} checked, {} errors, {} warnings",
             total.checked, total.errors, total.warnings).ok();
    drop(out);

    if total.errors > 0 { process::exit(1); }
}
