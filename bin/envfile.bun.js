#!/usr/bin/env bun
import { readFileSync } from "fs";
import { runEnvfile } from "../src/js/envfile.lib.mjs";

const exitCode = runEnvfile({
  args: Bun.argv.slice(2),
  env: process.env,
  readPath: (path) => readFileSync(path),
  readStdin: () => readFileSync(0),
  writeStdoutBytes: (bytes) => process.stdout.write(bytes),
  writeStderr: (text) => process.stderr.write(text),
});

process.exit(exitCode);
