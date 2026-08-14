// safegamingOS — generates branded PNG assets with a built-in pixel font:
//   * 8 plymouth logo variants (logo-0..7.png, RGBA, hue rotated per bounce)
//   * KDE wallpaper (1920x1080)
//   * syslinux splash.png (640x480, RGB for maximum vesamenu compatibility)
// Run: bun run gen:assets  (or: node scripts/gen-assets.mjs)
import { deflateSync } from "node:zlib";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));

// ---------------------------------------------------------------------------
// minimal PNG encoder (RGBA or RGB, 8-bit, no interlace)
// ---------------------------------------------------------------------------
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const typeBuf = Buffer.from(type, "ascii");
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])));
  return Buffer.concat([len, typeBuf, data, crcBuf]);
}

/**
 * @param {number} w width
 * @param {number} h height
 * @param {Uint8Array} pixels  raw pixel data (w*h*channels)
 * @param {2|6} colorType 6 = RGBA, 2 = RGB
 */
function encodePNG(w, h, pixels, colorType = 6) {
  const channels = colorType === 6 ? 4 : 3;
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = colorType;
  const raw = Buffer.alloc((w * channels + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * channels + 1)] = 0; // filter: none
    const src = pixels.subarray(y * w * channels, (y + 1) * w * channels);
    raw.set(src, y * (w * channels + 1) + 1);
  }
  const idat = deflateSync(raw, { level: 9 });
  return Buffer.concat([sig, chunk("IHDR", ihdr), chunk("IDAT", idat), chunk("IEND", Buffer.alloc(0))]);
}

// ---------------------------------------------------------------------------
// tiny 5x7 pixel font (uppercase) — glyphs needed for SAFEGAMINGOS
// ---------------------------------------------------------------------------
const GLYPHS = {
  A: ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
  E: ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
  F: ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
  G: ["01110", "10001", "10000", "10111", "10001", "10001", "01110"],
  I: ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
  M: ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
  N: ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
  O: ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
  S: ["01110", "10001", "10000", "01110", "00001", "10001", "01110"],
};

const GLYPH_W = 5;
const GLYPH_H = 7;

// ---------------------------------------------------------------------------
// color helpers
// ---------------------------------------------------------------------------
function hexToRgb(hex) {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function hslToRgb(h, s, l) {
  h = ((h % 360) + 360) % 360;
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = l - c / 2;
  let r = 0, g = 0, b = 0;
  if (h < 60) [r, g, b] = [c, x, 0];
  else if (h < 120) [r, g, b] = [x, c, 0];
  else if (h < 180) [r, g, b] = [0, c, x];
  else if (h < 240) [r, g, b] = [0, x, c];
  else if (h < 300) [r, g, b] = [x, 0, c];
  else [r, g, b] = [c, 0, x];
  return [Math.round((r + m) * 255), Math.round((g + m) * 255), Math.round((b + m) * 255)];
}

const lerp = (a, b, t) => a + (b - a) * t;

// ---------------------------------------------------------------------------
// pixel-text rendering into an RGBA canvas
// ---------------------------------------------------------------------------
/**
 * Draw a word with the pixel font.
 * @param {(x:number, y:number, w:number, h:number) => [number,number,number,number]} colorFn
 *        returns [r,g,b,a] for a glyph cell (a=0 means skip)
 */
function drawWord(word, cell, spacingCells, colorFn) {
  const spacing = cell * spacingCells;
  const width = word.length * GLYPH_W * cell + (word.length - 1) * spacing;
  const height = GLYPH_H * cell;
  const px = new Uint8Array(width * height * 4);
  let x0 = 0;
  for (const ch of word) {
    const glyph = GLYPHS[ch];
    if (!glyph) continue;
    for (let row = 0; row < GLYPH_H; row++) {
      for (let col = 0; col < GLYPH_W; col++) {
        if (glyph[row][col] !== "1") continue;
        const [r, g, b, a] = colorFn(x0 + col * cell, row * cell, cell, cell);
        if (a <= 0) continue;
        for (let dy = 0; dy < cell; dy++) {
          for (let dx = 0; dx < cell; dx++) {
            const X = x0 + col * cell + dx;
            const Y = row * cell + dy;
            const i = (Y * width + X) * 4;
            px[i] = r;
            px[i + 1] = g;
            px[i + 2] = b;
            px[i + 3] = a;
          }
        }
      }
    }
    x0 += GLYPH_W * cell + spacing;
  }
  return { width, height, px };
}

// ---------------------------------------------------------------------------
// 1) plymouth logo variants — hue rotates for the DVD bounce effect
// ---------------------------------------------------------------------------
function makeLogos() {
  const WORD = "SAFEGAMINGOS";
  const cell = 12;
  const outDir = join(ROOT, "archiso/airootfs/usr/share/plymouth/themes/safegamingos");
  mkdirSync(outDir, { recursive: true });

  const baseHue = 145; // neon green
  for (let v = 0; v < 8; v++) {
    const hue = baseHue + v * 45;
    const { width, height, px } = drawWord(WORD, cell, 2, (_x, _y, _w, _h) => {
      const [r, g, b] = hslToRgb(hue, 0.85, 0.62);
      return [r, g, b, 255];
    });
    // subtle glow: dark outline around the whole text block
    const glow = new Uint8Array(width * height * 4);
    const dark = hslToRgb(hue, 0.9, 0.4);
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const i = (y * width + x) * 4;
        const lit = px[i + 3] > 0;
        if (lit) {
          glow[i] = px[i];
          glow[i + 1] = px[i + 1];
          glow[i + 2] = px[i + 2];
          glow[i + 3] = 255;
        } else {
          // check 4-neighborhood for a lit pixel → outline
          let edge = false;
          for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
            const nx = x + dx, ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
            if (px[(ny * width + nx) * 4 + 3] > 0) edge = true;
          }
          if (edge) {
            glow[i] = dark[0];
            glow[i + 1] = dark[1];
            glow[i + 2] = dark[2];
            glow[i + 3] = 180;
          }
        }
      }
    }
    const file = join(outDir, `logo-${v}.png`);
    writeFileSync(file, encodePNG(width, height, glow, 6));
    console.log(`  ${file} (${width}x${height})`);
  }
}

// ---------------------------------------------------------------------------
// 2) KDE wallpaper 1920x1080
// ---------------------------------------------------------------------------
function makeWallpaper() {
  const W = 1920, H = 1080;
  const px = new Uint8Array(W * H * 4);
  const top = hexToRgb("#070b12");
  const bottom = hexToRgb("#0d1522");
  const accent = hexToRgb("#22d3ee");
  const accent2 = hexToRgb("#4ade80");

  // vertical gradient + subtle vignette
  for (let y = 0; y < H; y++) {
    const t = y / (H - 1);
    const r = lerp(top[0], bottom[0], t);
    const g = lerp(top[1], bottom[1], t);
    const b = lerp(top[2], bottom[2], t);
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      // soft vignette
      const dx = (x / W - 0.5) * 2;
      const dy = (y / H - 0.5) * 2;
      const vig = Math.max(0, 1 - (dx * dx + dy * dy) * 0.55);
      px[i] = Math.min(255, Math.round(r * (0.75 + 0.25 * vig)));
      px[i + 1] = Math.min(255, Math.round(g * (0.75 + 0.25 * vig)));
      px[i + 2] = Math.min(255, Math.round(b * (0.75 + 0.25 * vig)));
      px[i + 3] = 255;
    }
  }

  // faint pixel grid in the center band
  for (let gy = 0; gy < H; gy += 27) {
    for (let gx = 0; gx < W; gx += 27) {
      const i = (gy * W + gx) * 4;
      px[i] = Math.min(255, px[i] + 6);
      px[i + 1] = Math.min(255, px[i + 1] + 6);
      px[i + 2] = Math.min(255, px[i + 2] + 6);
    }
  }

  // big faint logo in the upper-center
  const WORD = "SAFEGAMINGOS";
  const cell = 20;
  const { width: lw, height: lh, px: logoPx } = drawWord(WORD, cell, 2, (_x, _y, _w, _h) => [180, 240, 220, 255]);
  const ox = Math.round((W - lw) / 2);
  const oy = Math.round(H * 0.28 - lh / 2);
  for (let y = 0; y < lh; y++) {
    for (let x = 0; x < lw; x++) {
      const li = (y * lw + x) * 4;
      const a = logoPx[li + 3];
      if (a === 0) continue;
      const X = ox + x, Y = oy + y;
      if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
      const i = (Y * W + X) * 4;
      const alpha = 0.10; // faint watermark
      px[i] = Math.round(px[i] * (1 - alpha) + logoPx[li] * alpha);
      px[i + 1] = Math.round(px[i + 1] * (1 - alpha) + logoPx[li + 1] * alpha);
      px[i + 2] = Math.round(px[i + 2] * (1 - alpha) + logoPx[li + 2] * alpha);
    }
  }

  // two accent lines under the logo
  const lineY = oy + lh + 60;
  const half = Math.round(W * 0.18);
  const cx = Math.round(W / 2);
  for (let x = cx - half; x < cx; x++) {
    setPx(px, W, H, x, lineY, accent, 200);
    setPx(px, W, H, x, lineY - 3, accent2, 140);
  }
  for (let x = cx; x < cx + half; x++) {
    setPx(px, W, H, x, lineY, accent2, 200);
    setPx(px, W, H, x, lineY - 3, accent, 140);
  }

  const outDir = join(ROOT, "archiso/airootfs/usr/share/wallpapers");
  mkdirSync(outDir, { recursive: true });
  const file = join(outDir, "safegamingos.png");
  writeFileSync(file, encodePNG(W, H, px, 6));
  console.log(`  ${file} (${W}x${H})`);
}

function setPx(px, W, H, x, y, [r, g, b], a) {
  if (x < 0 || y < 0 || x >= W || y >= H) return;
  const i = (y * W + x) * 4;
  const alpha = a / 255;
  px[i] = Math.round(px[i] * (1 - alpha) + r * alpha);
  px[i + 1] = Math.round(px[i + 1] * (1 - alpha) + g * alpha);
  px[i + 2] = Math.round(px[i + 2] * (1 - alpha) + b * alpha);
  px[i + 3] = 255;
}

// ---------------------------------------------------------------------------
// 3) syslinux splash.png (RGB, 640x480)
// ---------------------------------------------------------------------------
function makeSplash() {
  const W = 640, H = 480;
  const px = new Uint8Array(W * H * 3);
  const top = hexToRgb("#0a101c");
  const bottom = hexToRgb("#101a2c");
  for (let y = 0; y < H; y++) {
    const t = y / (H - 1);
    const r = lerp(top[0], bottom[0], t);
    const g = lerp(top[1], bottom[1], t);
    const b = lerp(top[2], bottom[2], t);
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 3;
      const dx = (x / W - 0.5) * 2;
      const dy = (y / H - 0.5) * 2;
      const vig = Math.max(0, 1 - (dx * dx + dy * dy) * 0.5);
      px[i] = Math.round(r * (0.8 + 0.2 * vig));
      px[i + 1] = Math.round(g * (0.8 + 0.2 * vig));
      px[i + 2] = Math.round(b * (0.8 + 0.2 * vig));
    }
  }

  // logo centered (fits: 11 chars * 5*8 + 10*2*8 = 600px)
  const WORD = "SAFEGAMINGOS";
  const cell = 8;
  const { width: lw, height: lh, px: logoPx } = drawWord(WORD, cell, 2, (_x, _y, _w, _h) => {
    const [r, g, b] = hslToRgb(145, 0.8, 0.6);
    return [r, g, b, 255];
  });
  const ox = Math.round((W - lw) / 2);
  const oy = Math.round((H - lh) / 2) - 20;
  for (let y = 0; y < lh; y++) {
    for (let x = 0; x < lw; x++) {
      const li = (y * lw + x) * 4;
      if (logoPx[li + 3] === 0) continue;
      const X = ox + x, Y = oy + y;
      if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
      const i = (Y * W + X) * 3;
      px[i] = logoPx[li];
      px[i + 1] = logoPx[li + 1];
      px[i + 2] = logoPx[li + 2];
    }
  }

  const outDir = join(ROOT, "archiso/syslinux");
  mkdirSync(outDir, { recursive: true });
  const file = join(outDir, "splash.png");
  writeFileSync(file, encodePNG(W, H, px, 2));
  console.log(`  ${file} (${W}x${H})`);
}

console.log("safegamingOS — generating assets");
makeLogos();
makeWallpaper();
makeSplash();
console.log("done");
