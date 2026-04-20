import { readFileSync } from "fs";
import { lint } from "./envfile.js";

const format = process.env.ENVFILE_FORMAT || "shell";
const action = process.env.ENVFILE_ACTION || "validate";

const files = process.argv.slice(2);
if (files.length === 0) files.push("-");

const read = (p) => {
  if (p === "-") return readFileSync(0, "utf8");
  return readFileSync(p, "utf8");
};

const { diag, norm, errors } = lint(files, read, { format, action });
if (norm) process.stdout.write(norm.join(""));
process.stderr.write(diag.join(""));
process.exit(errors > 0 ? 1 : 0);
