// safegamingOS — minimal zero-dependency static preview server.
// Serves ./preview on PORT (default 4173), bound to 0.0.0.0.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../preview/", import.meta.url));
const PORT = Number(process.env.PORT) || 4173;

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
};

createServer(async (req, res) => {
  try {
    const urlPath = decodeURIComponent(new URL(req.url ?? "/", "http://localhost").pathname);
    const rel = urlPath === "/" ? "index.html" : urlPath.replace(/^\/+/, "");
    const file = join(ROOT, rel);
    if (!file.startsWith(ROOT)) {
      res.writeHead(403, { "content-type": "text/plain; charset=utf-8" });
      res.end("Forbidden");
      return;
    }
    const data = await readFile(file);
    res.writeHead(200, { "content-type": MIME[extname(file)] ?? "application/octet-stream" });
    res.end(data);
  } catch {
    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("safegamingOS preview: 404 — no such file");
  }
}).listen(PORT, "0.0.0.0", () => {
  console.log(`safegamingOS preview running on http://0.0.0.0:${PORT}`);
});
