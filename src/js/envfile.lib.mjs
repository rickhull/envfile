// envfile.lib.mjs — shared JS implementation for node/bun/deno

const UTF8 = new TextEncoder();

const BOM_BYTES = new Uint8Array([0xef, 0xbb, 0xbf]);

function bytesToLatin1(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return s;
}

function stringToBytes(s) {
  return UTF8.encode(s);
}

function toBytes(data) {
  if (data instanceof Uint8Array) return data;
  if (typeof data === "string") return stringToBytes(data);
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  throw new Error("unsupported byte source");
}

function splitLines(buf) {
  const lines = [];
  let start = 0;
  for (let i = 0; i < buf.length; i++) {
    if (buf[i] === 0x0a) {
      lines.push(buf.slice(start, i));
      start = i + 1;
    }
  }
  lines.push(buf.slice(start));
  if (lines.length > 0 && lines[lines.length - 1].length === 0) lines.pop();
  return lines;
}

function isContinuation(line) {
  let n = 0;
  for (let i = line.length - 1; i >= 0 && line[i] === 0x5c; i--) n++;
  return (n & 1) === 1;
}

function isBlankSpacesTabs(line) {
  for (const c of line) if (c !== 0x20 && c !== 0x09) return false;
  return true;
}

function indexOfByte(line, byte) {
  for (let i = 0; i < line.length; i++) if (line[i] === byte) return i;
  return -1;
}

function startsWithBytes(line, prefix) {
  if (line.length < prefix.length) return false;
  for (let i = 0; i < prefix.length; i++) if (line[i] !== prefix[i]) return false;
  return true;
}

function validShellKey(key) {
  if (key.length === 0) return false;
  const first = key[0];
  if (!((first >= 65 && first <= 90) || (first >= 97 && first <= 122) || first === 95)) return false;
  for (let i = 1; i < key.length; i++) {
    const c = key[i];
    if (!((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c === 95)) return false;
  }
  return true;
}

function isNameStart(c) {
  return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95;
}

function isNameContinue(c) {
  return isNameStart(c) || (c >= 48 && c <= 57);
}

function writeKV(writeStdoutBytes, key, value) {
  const out = new Uint8Array(key.length + 1 + value.length + 1);
  out.set(key, 0);
  out[key.length] = 0x3d;
  out.set(value, key.length + 1);
  out[out.length - 1] = 0x0a;
  writeStdoutBytes(out);
}

export function runEnvfile({ args, env, readPath, readStdin, writeStdoutBytes, writeStderr }) {
  const format = env.ENVFILE_FORMAT || "shell";
  const action = env.ENVFILE_ACTION || "validate";
  const bom = env.ENVFILE_BOM || (format === "native" ? "literal" : "strip");
  const crlf = env.ENVFILE_CRLF || "ignore";
  const nul = env.ENVFILE_NUL || "reject";
  const cont = env.ENVFILE_BACKSLASH_CONTINUATION || "ignore";

  if (bom !== "literal" && bom !== "strip" && bom !== "reject") {
    writeStderr(`FATAL_ERROR_BAD_ENVFILE_VALUE: ENVFILE_BOM=${bom}\n`);
    return 1;
  }
  if (format === "native" && bom !== "literal") {
    writeStderr(`FATAL_ERROR_UNSUPPORTED: format=native ENVFILE_BOM=${bom}\n`);
    return 1;
  }

  const files = args.length > 0 ? [...args] : ["-"];
  let checked = 0;
  let errors = 0;

  const envMap = new Map();
  const envKeys = new Map();

  function diag(path, lineno, code) {
    writeStderr(`${code}: ${path}:${lineno}\n`);
    errors++;
  }

  function fdiag(path, code) {
    writeStderr(`${code}: ${path}\n`);
    errors++;
  }

  function seedEnv() {
    for (const [k, v] of Object.entries(env)) {
      if (k.startsWith("ENVFILE_")) continue;
      const kb = stringToBytes(k);
      const ks = bytesToLatin1(kb);
      envMap.set(ks, stringToBytes(v));
      envKeys.set(ks, kb);
    }
  }

  function substValue(path, lineno, value) {
    const out = [];
    let i = 0;
    while (i < value.length) {
      let pos = -1;
      for (let j = i; j < value.length; j++) {
        if (value[j] === 0x24) {
          pos = j;
          break;
        }
      }
      if (pos < 0) {
        for (let j = i; j < value.length; j++) out.push(value[j]);
        break;
      }

      for (let j = i; j < pos; j++) out.push(value[j]);
      if (pos + 1 >= value.length) {
        out.push(0x24);
        break;
      }

      const rest = value.slice(pos + 1);
      let name;
      if (rest[0] === 0x7b) {
        const close = indexOfByte(rest.slice(1), 0x7d);
        if (close < 0) {
          out.push(0x24);
          for (const c of rest) out.push(c);
          break;
        }
        name = rest.slice(1, 1 + close);
        i = pos + close + 3;
      } else {
        if (!isNameStart(rest[0])) {
          out.push(0x24);
          i = pos + 1;
          continue;
        }
        let j = 1;
        while (j < rest.length && isNameContinue(rest[j])) j++;
        name = rest.slice(0, j);
        i = pos + 1 + j;
      }

      const nameKey = bytesToLatin1(name);
      const resolved = envMap.get(nameKey);
      if (resolved) {
        for (const c of resolved) out.push(c);
      } else {
        writeStderr(`LINE_ERROR_UNBOUND_REF (${nameKey}): ${path}:${lineno}\n`);
        errors++;
      }
    }
    return Uint8Array.from(out);
  }

  function unquoteShellValue(path, lineno, value) {
    if (value.length === 0) return value;
    const c = value[0];
    if (c === 0x22 || c === 0x27) {
      const rest = value.slice(1);
      const pos = indexOfByte(rest, c);
      if (pos < 0) {
        diag(path, lineno, c === 0x22 ? "LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED" : "LINE_ERROR_SINGLE_QUOTE_UNTERMINATED");
        return null;
      }
      if (rest.slice(pos + 1).length !== 0) {
        diag(path, lineno, "LINE_ERROR_TRAILING_CONTENT");
        return null;
      }
      return rest.slice(0, pos);
    }
    for (const ch of value) {
      if (ch === 0x20 || ch === 0x09 || ch === 0x27 || ch === 0x22 || ch === 0x5c) {
        diag(path, lineno, "LINE_ERROR_VALUE_INVALID_CHAR");
        return null;
      }
    }
    return value;
  }

  function handleRecord(path, lineno, key, rawValue, value) {
    if (action === "dump") {
      writeKV(writeStdoutBytes, key, value);
      return;
    }
    if (action === "validate" || action === "normalize") return;

    const resolved = (format === "native" || !(rawValue.length > 0 && rawValue[0] === 0x27))
      ? substValue(path, lineno, value)
      : value.slice();

    const keyStr = bytesToLatin1(key);
    envMap.set(keyStr, resolved);
    envKeys.set(keyStr, key.slice());
    if (action === "delta") writeKV(writeStdoutBytes, key, resolved);
  }

  if (action === "delta" || action === "apply") seedEnv();

  for (const path of files) {
    let fileBytes;
    try {
      fileBytes = toBytes(path === "-" ? readStdin() : readPath(path));
    } catch {
      fdiag(path, "FILE_ERROR_FILE_UNREADABLE");
      continue;
    }

    if (nul === "reject" && indexOfByte(fileBytes, 0x00) >= 0) {
      fdiag(path, "FILE_ERROR_NUL");
      continue;
    }

    let lines = splitLines(fileBytes);

    if (lines.length > 0 && startsWithBytes(lines[0], BOM_BYTES)) {
      if (bom === "reject") {
        fdiag(path, "FILE_ERROR_BOM");
        continue;
      }
      if (bom === "strip") lines[0] = lines[0].slice(3);
    }

    if (crlf === "strip") {
      let allCRLF = lines.length > 0;
      for (const line of lines) {
        if (line.length === 0 || line[line.length - 1] !== 0x0d) {
          allCRLF = false;
          break;
        }
      }
      if (allCRLF) lines = lines.map((line) => line.slice(0, line.length - 1));
    }

    const procLines = [];
    if (cont === "accept") {
      let i = 0;
      while (i < lines.length) {
        let line = lines[i].slice();
        let lineno = i + 1;
        i++;
        while (isContinuation(line) && i < lines.length) {
          line = new Uint8Array([...line.slice(0, line.length - 1), ...lines[i]]);
          lineno = i + 1;
          i++;
        }
        procLines.push({ line, lineno });
      }
    } else {
      for (let i = 0; i < lines.length; i++) procLines.push({ line: lines[i], lineno: i + 1 });
    }

    for (const { line, lineno } of procLines) {
      const trimmed = line.length > 0 && line[line.length - 1] === 0x0d ? line.slice(0, line.length - 1) : line;
      if (isBlankSpacesTabs(trimmed)) continue;
      if (trimmed.length > 0 && trimmed[0] === 0x23) continue;

      checked++;

      const eq = indexOfByte(line, 0x3d);
      if (eq < 0) {
        diag(path, lineno, "LINE_ERROR_NO_EQUALS");
        continue;
      }
      const rawKey = line.slice(0, eq);
      const rawValue = line.slice(eq + 1);

      if (action === "normalize") {
        writeKV(writeStdoutBytes, rawKey, rawValue);
        continue;
      }

      const work = format === "native" ? line : trimmed;
      const eq2 = indexOfByte(work, 0x3d);
      if (eq2 < 0) {
        diag(path, lineno, "LINE_ERROR_NO_EQUALS");
        continue;
      }

      const key = work.slice(0, eq2);
      const value = work.slice(eq2 + 1);

      if (format === "native") {
        if (key.length === 0) {
          diag(path, lineno, "LINE_ERROR_EMPTY_KEY");
          continue;
        }
        handleRecord(path, lineno, key, rawValue, value);
        continue;
      }

      if (key.length > 0 && (key[0] === 0x20 || key[0] === 0x09)) {
        diag(path, lineno, "LINE_ERROR_KEY_LEADING_WHITESPACE");
        continue;
      }
      if (key.length > 0 && (key[key.length - 1] === 0x20 || key[key.length - 1] === 0x09)) {
        diag(path, lineno, "LINE_ERROR_KEY_TRAILING_WHITESPACE");
        continue;
      }
      if (value.length > 0 && (value[0] === 0x20 || value[0] === 0x09)) {
        diag(path, lineno, "LINE_ERROR_VALUE_LEADING_WHITESPACE");
        continue;
      }
      if (key.length === 0) {
        diag(path, lineno, "LINE_ERROR_EMPTY_KEY");
        continue;
      }
      if (!validShellKey(key)) {
        diag(path, lineno, "LINE_ERROR_KEY_INVALID");
        continue;
      }

      const unquoted = unquoteShellValue(path, lineno, value);
      if (unquoted === null) continue;
      handleRecord(path, lineno, key, rawValue, unquoted);
    }
  }

  if (action === "apply") {
    const keys = [...envKeys.keys()].filter((k) => !k.startsWith("ENVFILE_")).sort();
    for (const k of keys) writeKV(writeStdoutBytes, envKeys.get(k), envMap.get(k));
  }

  writeStderr(`${checked} checked, ${errors} errors\n`);
  return errors > 0 ? 1 : 0;
}
