#!/usr/bin/env -S deno run --allow-read --allow-env
import { runEnvfile } from "../src/js/envfile.lib.mjs";

const encoder = new TextEncoder();

const readStdin = () => {
  const chunks = [];
  let total = 0;
  while (true) {
    const buf = new Uint8Array(65536);
    const n = Deno.stdin.readSync(buf);
    if (n === null) break;
    chunks.push(buf.slice(0, n));
    total += n;
  }
  const out = new Uint8Array(total);
  let off = 0;
  for (const chunk of chunks) {
    out.set(chunk, off);
    off += chunk.length;
  }
  return out;
};

const env = {};
for (const [k, v] of Object.entries(Deno.env.toObject())) env[k] = v;

const exitCode = runEnvfile({
  args: Deno.args,
  env,
  readPath: (path) => Deno.readFileSync(path),
  readStdin,
  writeStdoutBytes: (bytes) => Deno.stdout.writeSync(bytes),
  writeStderr: (text) => Deno.stderr.writeSync(encoder.encode(text)),
});

Deno.exit(exitCode);
