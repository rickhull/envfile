#!/usr/bin/env bun
import { lint } from "../src/js/envfile.js";
import { readFileSync } from "fs";

const format = process.env.ENVFILE_FORMAT || "strict";
const action = process.env.ENVFILE_ACTION || "validate";

const files = Bun.argv.slice(2);
if (files.length === 0) files.push("-");

const read = (p) => {
  if (p === "-") {
    const bytes = Bun.stdin.readSync();
    return new TextDecoder().decode(bytes);
  }
  return readFileSync(p, "utf8");
};

const { diag, norm, errors } = lint(files, read, { format, action });
if (norm) process.stdout.write(norm.join(""));
process.stderr.write(diag.join(""));
process.exit(errors > 0 ? 1 : 0);
