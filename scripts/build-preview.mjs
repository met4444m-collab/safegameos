// safegamingOS — build the static preview output into ./dist.
import { cpSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));

rmSync(join(ROOT, "dist"), { recursive: true, force: true });
mkdirSync(join(ROOT, "dist"), { recursive: true });
cpSync(join(ROOT, "preview"), join(ROOT, "dist"), { recursive: true });
console.log("safegamingOS: static preview built into dist/");
