// lint.js — validate env files (see README.md)

const ERROR_NO_EQUALS                 = "missing assignment (=)";
const ERROR_KEY_LEADING_WHITESPACE    = "leading whitespace before key";
const ERROR_KEY_TRAILING_WHITESPACE   = "whitespace before =";
const ERROR_VALUE_LEADING_WHITESPACE  = "whitespace after =";
const ERROR_KEY_INVALID               = "invalid key";
const ERROR_DOUBLE_QUOTE_UNTERMINATED = "unterminated double quote";
const ERROR_SINGLE_QUOTE_UNTERMINATED = "unterminated single quote";
const ERROR_TRAILING_CONTENT          = "trailing content after closing quote";
const ERROR_VALUE_INVALID_CHAR        = "value contains whitespace, quote, or backslash";
const WARN_KEY_NOT_UPPERCASE          = "is not UPPERCASE (preferred)";

const KEY_RE     = /^[A-Za-z_][A-Za-z0-9_]*$/;
const BAD_VAL_RE = /[\s'"\\]/;

function lintLines(path, lines) {
  let checked = 0, errors = 0, warnings = 0;
  const out = [];

  const error   = (n, msg) => { out.push(`ERROR: (${path}:${n}) ${msg}`); errors++; };
  const warning = (n, msg) => { out.push(`WARNING: (${path}:${n}) ${msg}`); warnings++; };

  for (let i = 0; i < lines.length; i++) {
    const n = i + 1;
    let line = lines[i].replace(/\r$/, "");

    if (!line.trim()) continue;
    if (line.startsWith("#")) continue;
    checked++;

    const eq = line.indexOf("=");
    if (eq === -1) { error(n, ERROR_NO_EQUALS); continue; }

    const k = line.slice(0, eq);
    const v = line.slice(eq + 1);

    if (/^[\t ]/.test(k))  { error(n, ERROR_KEY_LEADING_WHITESPACE);   continue; }
    if (/[\t ]$/.test(k))  { error(n, ERROR_KEY_TRAILING_WHITESPACE);  continue; }
    if (v && /^[\t ]/.test(v)) { error(n, ERROR_VALUE_LEADING_WHITESPACE); continue; }
    if (!KEY_RE.test(k))   { error(n, `${ERROR_KEY_INVALID} '${k}'`);  continue; }
    if (k !== k.toUpperCase()) warning(n, `key '${k}' ${WARN_KEY_NOT_UPPERCASE}`);

    if (!v) continue;

    const c = v[0];
    if (c === '"' || c === "'") {
      const rest = v.slice(1);
      const pos  = rest.indexOf(c);
      if (pos === -1) {
        error(n, c === '"' ? ERROR_DOUBLE_QUOTE_UNTERMINATED : ERROR_SINGLE_QUOTE_UNTERMINATED);
        continue;
      }
      if (rest.slice(pos + 1)) { error(n, ERROR_TRAILING_CONTENT); continue; }
    } else {
      if (BAD_VAL_RE.test(v)) { error(n, ERROR_VALUE_INVALID_CHAR); continue; }
    }
  }

  return { checked, errors, warnings, out };
}

export function lint(files, readFileSync) {
  let totalChecked = 0, totalErrors = 0, totalWarnings = 0;
  const out = [];

  for (const path of files) {
    const content = readFileSync(path);
    const lines   = content.split("\n");
    const r = lintLines(path, lines);
    totalChecked  += r.checked;
    totalErrors   += r.errors;
    totalWarnings += r.warnings;
    out.push(...r.out);
  }

  out.push(`${totalChecked} checked, ${totalErrors} errors, ${totalWarnings} warnings`);
  return { out, errors: totalErrors };
}
