import { readFileSync } from "fs";
import { lint } from "./lint.js";

const { out, errors } = lint(process.argv.slice(2), (p) => readFileSync(p, "utf8"));
process.stderr.write(out.join("\n") + "\n");
process.exit(errors > 0 ? 1 : 0);
