// envfile.js — validate/normalize env files (see README.md)

const ERROR_NO_EQUALS                 = "ERROR_NO_EQUALS";
const ERROR_EMPTY_KEY                 = "ERROR_EMPTY_KEY";
const ERROR_KEY_LEADING_WHITESPACE    = "ERROR_KEY_LEADING_WHITESPACE";
const ERROR_KEY_TRAILING_WHITESPACE   = "ERROR_KEY_TRAILING_WHITESPACE";
const ERROR_VALUE_LEADING_WHITESPACE  = "ERROR_VALUE_LEADING_WHITESPACE";
const ERROR_KEY_INVALID               = "ERROR_KEY_INVALID";
const ERROR_DOUBLE_QUOTE_UNTERMINATED = "ERROR_DOUBLE_QUOTE_UNTERMINATED";
const ERROR_SINGLE_QUOTE_UNTERMINATED = "ERROR_SINGLE_QUOTE_UNTERMINATED";
const ERROR_TRAILING_CONTENT          = "ERROR_TRAILING_CONTENT";
const ERROR_VALUE_INVALID_CHAR        = "ERROR_VALUE_INVALID_CHAR";

const KEY_RE        = /^[A-Za-z_][A-Za-z0-9_]*$/;
const NATIVE_KEY_RE = /^[A-Z_][A-Z0-9_]*$/;
const BAD_VAL_RE    = /[\s'"\\]/;

function nativeLines(path, lines, norm, diag) {
  let checked = 0, errors = 0;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.includes("\0")) {
      diag.push(`${ERROR_VALUE_INVALID_CHAR}: ${path}:${i+1}\n`);
      checked++;
      errors++;
      continue;
    }
    if (!line || !/\S/.test(line)) continue;
    if (line.charCodeAt(0) === 35) continue;  // '#'
    checked++;

    const eq = line.indexOf("=");
    if (eq === -1) { diag.push(`${ERROR_NO_EQUALS}: ${path}:${i+1}\n`); errors++; continue; }

    const k = line.slice(0, eq);
    const v = line.slice(eq + 1);

    if (!k)                      { diag.push(`${ERROR_EMPTY_KEY}: ${path}:${i+1}\n`);   errors++; continue; }
    if (!NATIVE_KEY_RE.test(k))  { diag.push(`${ERROR_KEY_INVALID}: ${path}:${i+1}\n`); errors++; continue; }

    if (norm) norm.push(`${k}=${v}\n`);
  }

  return { checked, errors };
}

function shellLines(path, lines, norm, diag) {
  let checked = 0, errors = 0;

  for (let i = 0; i < lines.length; i++) {
    const n = i + 1;
    const line = lines[i];
    if (line.includes("\0")) {
      diag.push(`${ERROR_VALUE_INVALID_CHAR}: ${path}:${n}\n`);
      checked++;
      errors++;
      continue;
    }
    if (!line || !/\S/.test(line)) continue;
    if (line.charCodeAt(0) === 35) continue;  // '#'
    checked++;

    const eq = line.indexOf("=");
    if (eq === -1) { diag.push(`${ERROR_NO_EQUALS}: ${path}:${n}\n`); errors++; continue; }

    const k = line.slice(0, eq);
    const v = line.slice(eq + 1);

    if (/^[\t ]/.test(k))        { diag.push(`${ERROR_KEY_LEADING_WHITESPACE}: ${path}:${n}\n`);   errors++; continue; }
    if (/[\t ]$/.test(k))        { diag.push(`${ERROR_KEY_TRAILING_WHITESPACE}: ${path}:${n}\n`);  errors++; continue; }
    if (v && /^[\t ]/.test(v))   { diag.push(`${ERROR_VALUE_LEADING_WHITESPACE}: ${path}:${n}\n`); errors++; continue; }
    if (!k)                      { diag.push(`${ERROR_EMPTY_KEY}: ${path}:${n}\n`);              errors++; continue; }
    if (!KEY_RE.test(k))         { diag.push(`${ERROR_KEY_INVALID}: ${path}:${n}\n`);              errors++; continue; }

    if (!v) { if (norm) norm.push(`${k}=\n`); continue; }

    const c = v[0];
    if (c === '"' || c === "'") {
      const rest = v.slice(1);
      const pos  = rest.indexOf(c);
      if (pos === -1) {
        diag.push(`${c === '"' ? ERROR_DOUBLE_QUOTE_UNTERMINATED : ERROR_SINGLE_QUOTE_UNTERMINATED}: ${path}:${n}\n`);
        errors++; continue;
      }
      if (rest.slice(pos + 1)) { diag.push(`${ERROR_TRAILING_CONTENT}: ${path}:${n}\n`); errors++; continue; }
      if (norm) norm.push(`${k}=${rest.slice(0, pos)}\n`);
    } else {
      if (BAD_VAL_RE.test(v)) { diag.push(`${ERROR_VALUE_INVALID_CHAR}: ${path}:${n}\n`); errors++; continue; }
      if (norm) norm.push(`${k}=${v}\n`);
    }
  }

  return { checked, errors };
}

export function lint(files, read, opts = {}) {
  const format    = opts.format || "shell";
  const action    = opts.action || "validate";
  const normalize = action === "normalize";
  const native    = format === "native";

  const norm = normalize ? [] : null;
  const diag = [];
  let totalChecked = 0, totalErrors = 0;

  for (const path of files) {
    const content = read(path);
    const lines   = content.split("\n");
    if (!native) {
      for (let i = 0; i < lines.length; i++)
        if (lines[i].charCodeAt(lines[i].length - 1) === 13) lines[i] = lines[i].slice(0, -1);
    }
    const fn = native ? nativeLines : shellLines;
    const r  = fn(path, lines, norm, diag);
    totalChecked  += r.checked;
    totalErrors   += r.errors;
  }

  diag.push(`${totalChecked} checked, ${totalErrors} errors\n`);
  return { norm, diag, errors: totalErrors };
}
