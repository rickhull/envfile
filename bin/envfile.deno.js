#!/usr/bin/env -S deno run --allow-read --allow-env
import { lint } from "../src/js/envfile.js";

const format = Deno.env.get("ENVFILE_FORMAT") || "strict";
const action = Deno.env.get("ENVFILE_ACTION") || "validate";

const files = Deno.args;
if (files.length === 0) files.push("-");

const read = (p) => {
  if (p === "-") {
    const bytes = Deno.readAllSync(Deno.stdin);
    return new TextDecoder().decode(bytes);
  }
  return Deno.readTextFileSync(p);
};

const { diag, norm, errors } = lint(files, read, { format, action });
const enc = new TextEncoder();
if (norm) Deno.stdout.writeSync(enc.encode(norm.join("")));
Deno.stderr.writeSync(enc.encode(diag.join("")));
Deno.exit(errors > 0 ? 1 : 0);
