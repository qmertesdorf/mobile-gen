import { readFileSync, writeFileSync, mkdirSync, statSync, existsSync, readdirSync, copyFileSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join, basename } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

export const GAMES_DIR = process.env.GAMEFORGE_GAMES_DIR || join(REPO_ROOT, "games");
export const GODOT_DIR = join(__dirname, "godot"); // the tool-project for headless Image scripts
// 50 MiB default whole-title asset budget; override per-title via opts or env.
export const DEFAULT_SIZE_BUDGET = Number(process.env.GAMEFORGE_SIZE_BUDGET || 52428800);

// The canonical list of required Android icon outputs. Pure + deterministic;
// a fresh array each call so callers can't mutate a shared singleton.
export function iconSizeTable() {
  return [
    { name: "ic_launcher_mdpi", px: 48, kind: "launcher" },
    { name: "ic_launcher_hdpi", px: 72, kind: "launcher" },
    { name: "ic_launcher_xhdpi", px: 96, kind: "launcher" },
    { name: "ic_launcher_xxhdpi", px: 144, kind: "launcher" },
    { name: "ic_launcher_xxxhdpi", px: 192, kind: "launcher" },
    { name: "ic_play_store", px: 512, kind: "play" },
    { name: "ic_adaptive_foreground", px: 432, kind: "adaptive_fg" },
    { name: "ic_adaptive_background", px: 432, kind: "adaptive_bg" }
  ];
}

// Sum shippable asset bytes and compare to a budget. Pure.
export function sizeBudget(files, budgetBytes) {
  if (!Array.isArray(files)) {
    throw new Error("package: sizeBudget(files) requires an array of { path, bytes }");
  }
  if (typeof budgetBytes !== "number" || budgetBytes < 0) {
    throw new Error("package: sizeBudget budgetBytes must be a non-negative number");
  }
  const per_file = files.map((f) => {
    if (typeof f?.path !== "string" || typeof f?.bytes !== "number") {
      throw new Error(`package: sizeBudget entry must be { path:string, bytes:number }, got ${JSON.stringify(f)}`);
    }
    return { path: f.path, bytes: f.bytes };
  });
  const total = per_file.reduce((s, f) => s + f.bytes, 0);
  return { total, budget_bytes: budgetBytes, pass: total <= budgetBytes, per_file };
}

// Read a PNG's pixel dimensions straight from the IHDR chunk — no decode, no
// Godot. Lets the validator assert exact icon sizes headlessly. Pure.
export function pngSize(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 24) {
    throw new Error("package: pngSize requires a PNG buffer of at least 24 bytes");
  }
  const sig = buf.subarray(0, 8).toString("latin1");
  if (sig !== "\x89PNG\r\n\x1a\n") {
    throw new Error("package: pngSize: not a PNG (bad signature)");
  }
  if (buf.subarray(12, 16).toString("latin1") !== "IHDR") {
    throw new Error("package: pngSize: first chunk is not IHDR (corrupt PNG)");
  }
  return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
}

// Generate a minimal-but-valid Godot Android export_presets.cfg string. Pure.
export function exportPresetCfg({ id, name, packageName, exportPath } = {}) {
  if (!id || !name) {
    throw new Error("package: exportPresetCfg requires both { id, name }");
  }
  const unique = packageName || `com.gameforge.${id}`;
  const out = exportPath || `build/${id}-debug.apk`;
  return [
    "[preset.0]",
    "",
    `name="${name}"`,
    `platform="Android"`,
    "runnable=true",
    `export_filter="all_resources"`,
    `include_filter=""`,
    `exclude_filter=""`,
    `export_path="${out}"`,
    "",
    "[preset.0.options]",
    "",
    `package/unique_name="${unique}"`,
    `package/name="${name}"`,
    ""
  ].join("\n");
}

// Parse a Godot .cfg/export_presets.cfg into { section: { key: value } }.
// Strips surrounding quotes; coerces true/false and bare integers. Throws
// loudly on a malformed line so the validator can assert "the preset parses".
export function parsePresetCfg(text) {
  if (typeof text !== "string") {
    throw new Error("package: parsePresetCfg requires a string");
  }
  const sections = {};
  let current = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith(";")) continue; // Godot .cfg comment lines
    const sec = line.match(/^\[(.+)\]$/);
    if (sec) { current = sec[1]; sections[current] = {}; continue; }
    const kv = line.match(/^([^=]+)=(.*)$/);
    if (!kv) throw new Error(`package: parsePresetCfg: unparseable line: ${raw}`);
    if (current === null) throw new Error(`package: parsePresetCfg: key before any [section]: ${raw}`);
    let val = kv[2].trim();
    if (val.startsWith('"') && val.endsWith('"')) val = val.slice(1, -1);
    else if (val === "true") val = true;
    else if (val === "false") val = false;
    else if (/^-?\d+$/.test(val)) val = Number(val);
    sections[current][kv[1].trim()] = val;
  }
  return sections;
}

// Deterministic shelf bin-packing: tallest-first, left-to-right rows wrapping
// at maxWidth, sheet rounded up to power-of-two on both axes. Pure (no pixels).
export function atlasLayout(rects, { maxWidth = 1024, padding = 0 } = {}) {
  if (!Array.isArray(rects)) {
    throw new Error("package: atlasLayout(rects) requires an array of { name, w, h }");
  }
  const items = rects.map((r) => {
    if (typeof r?.name !== "string" || typeof r?.w !== "number" || typeof r?.h !== "number") {
      throw new Error(`package: atlasLayout entry must be { name:string, w:number, h:number }, got ${JSON.stringify(r)}`);
    }
    return { name: r.name, w: r.w, h: r.h };
  });
  if (items.length === 0) return { sheet: { w: 0, h: 0 }, placements: [] };

  // Deterministic order: tallest, then widest, then name — no Math.random / input order dependence.
  const sorted = [...items].sort((a, b) => b.h - a.h || b.w - a.w || (a.name < b.name ? -1 : 1));
  for (const r of sorted) {
    if (r.w + padding > maxWidth) {
      throw new Error(`package: atlasLayout sprite '${r.name}' width ${r.w + padding} exceeds maxWidth ${maxWidth}`);
    }
  }

  const placements = [];
  let shelfX = 0, shelfY = 0, shelfH = 0, usedW = 0;
  for (const r of sorted) {
    const w = r.w + padding, h = r.h + padding;
    if (shelfX + w > maxWidth) { shelfY += shelfH; shelfX = 0; shelfH = 0; } // wrap to a new shelf
    placements.push({ name: r.name, x: shelfX, y: shelfY, w: r.w, h: r.h });
    shelfX += w;
    usedW = Math.max(usedW, shelfX);
    shelfH = Math.max(shelfH, h);
  }
  const totalH = shelfY + shelfH;
  const pow2 = (n) => { let p = 1; while (p < n) p <<= 1; return p; };
  return { sheet: { w: pow2(usedW), h: pow2(totalH) }, placements };
}
