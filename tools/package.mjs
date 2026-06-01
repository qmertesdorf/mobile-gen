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

// Resolve the pinned Godot binary. PowerShell carries a `godot` shim; fall back
// to the winget install path the README/memory pin (godot-binary-path).
function godotBin() {
  return process.env.GODOT_BIN
    || "C:\\Users\\quint\\AppData\\Local\\Microsoft\\WinGet\\Packages\\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\\Godot_v4.6.3-stable_win64_console.exe";
}

function runGodot(args, label) {
  try {
    return execFileSync(godotBin(), args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch (e) {
    const out = `${e.stdout ?? ""}${e.stderr ?? ""}`;
    throw new Error(`package: Godot ${label} failed: ${out || e.message}`);
  }
}

// Resize the icon master into every iconSizeTable() entry under games/<id>/store/icons/.
export function generateIcons(id, { gamesDir = GAMES_DIR } = {}) {
  const m = JSON.parse(readFileSync(join(REPO_ROOT, "manifests", `${id}.json`), "utf8"));
  const master = m?.store_pass?.icon_master;
  if (!master) throw new Error(`package: generateIcons needs store_pass.icon_master in manifests/${id}.json`);
  const masterAbs = join(gamesDir, id, master);
  if (!existsSync(masterAbs)) throw new Error(`package: icon master not found at ${masterAbs}`);
  const outdir = join(gamesDir, id, "store", "icons");
  const specs = iconSizeTable().map((e) => `${e.name}:${e.px}`).join(",");
  const out = runGodot(["--headless", "--path", GODOT_DIR, "--script", "res://icon_resize.gd", "--", masterAbs, outdir, specs], "icon_resize");
  if (!out.includes("ICON_RESIZE OK")) throw new Error(`package: icon_resize did not report OK:\n${out}`);
  return { outdir, icons: iconSizeTable().map((e) => ({ ...e, source: `store/icons/${e.name}.png` })) };
}

// Build the atlas layout from the game's raster sprites, write the map JSON, render the sheet.
export function generateAtlas(id, { gamesDir = GAMES_DIR } = {}) {
  const artDir = join(gamesDir, id, "art");
  const sprites = existsSync(artDir) ? readdirSync(artDir).filter((f) => f.endsWith(".png")) : [];
  if (sprites.length === 0) throw new Error(`package: no .png sprites under ${artDir} to atlas`);
  const rects = sprites.map((f) => {
    const { w, h } = pngSize(readFileSync(join(artDir, f)));
    return { name: basename(f, ".png"), w, h };
  });
  const layout = atlasLayout(rects);
  const storeDir = join(gamesDir, id, "store");
  mkdirSync(storeDir, { recursive: true });
  const mapPath = join(storeDir, "atlas.json");
  writeFileSync(mapPath, JSON.stringify(layout, null, 2) + "\n");
  const sheetPath = join(storeDir, "atlas.png");
  const out = runGodot(["--headless", "--path", GODOT_DIR, "--script", "res://atlas_render.gd", "--", mapPath, artDir, sheetPath], "atlas_render");
  if (!out.includes("ATLAS_RENDER OK")) throw new Error(`package: atlas_render did not report OK:\n${out}`);
  return { sheet: "store/atlas.png", map: "store/atlas.json", sprite_count: rects.length, layout };
}

// Capture one gameplay screenshot on the real renderer (copies the harness in, runs, cleans up).
export function captureScreenshot(id, name, { gamesDir = GAMES_DIR, frames = 220 } = {}) {
  const gameDir = join(gamesDir, id);
  const harnessSrc = join(GODOT_DIR, "screenshot.gd");
  const harnessDst = join(gameDir, "_screenshot.gd");
  const storeDir = join(gameDir, "store", "screenshots");
  mkdirSync(storeDir, { recursive: true });
  const outPath = join(storeDir, `${name}.png`);
  copyFileSync(harnessSrc, harnessDst);
  try {
    const out = runGodot(["--path", gameDir, "--script", "res://_screenshot.gd", "--", outPath, String(frames)], "screenshot");
    if (!out.includes("SCREENSHOT OK")) throw new Error(`package: screenshot did not report OK:\n${out}`);
  } finally {
    rmSync(harnessDst, { force: true });
  }
  return { name, source: `store/screenshots/${name}.png`, path: outPath };
}

// Sum the committed store assets and compare to the budget. File-based; pure math via sizeBudget.
export function budgetReport(id, { gamesDir = GAMES_DIR, budgetBytes = DEFAULT_SIZE_BUDGET } = {}) {
  const storeDir = join(gamesDir, id, "store");
  const files = [];
  const walk = (dir) => {
    if (!existsSync(dir)) return;
    for (const ent of readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, ent.name);
      if (ent.isDirectory()) walk(p);
      else files.push({ path: p.slice(join(gamesDir, id).length + 1).replace(/\\/g, "/"), bytes: statSync(p).size });
    }
  };
  walk(storeDir);
  return sizeBudget(files, budgetBytes);
}

// Validator Method 5's headless, no-SDK assertions. Throws on the first hard failure.
export function verify(id, { gamesDir = GAMES_DIR } = {}) {
  const m = JSON.parse(readFileSync(join(REPO_ROOT, "manifests", `${id}.json`), "utf8"));
  const sp = m.store_pass;
  if (!sp) throw new Error(`package: verify: manifests/${id}.json has no store_pass`);
  const issues = [];

  // 1. every iconSizeTable entry exists at its exact px
  for (const want of iconSizeTable()) {
    const rec = (sp.icons || []).find((i) => i.name === want.name);
    if (!rec) { issues.push(`missing icon ${want.name}`); continue; }
    const abs = join(gamesDir, id, rec.source);
    if (!existsSync(abs)) { issues.push(`icon file absent: ${rec.source}`); continue; }
    const { w, h } = pngSize(readFileSync(abs));
    if (w !== want.px || h !== want.px) issues.push(`icon ${want.name} is ${w}x${h}, expected ${want.px}x${want.px}`);
  }

  // 2. atlas sheet exists and its map covers every member sprite
  if (sp.atlas) {
    const sheetAbs = join(gamesDir, id, sp.atlas.sheet);
    const mapAbs = join(gamesDir, id, sp.atlas.map);
    if (!existsSync(sheetAbs)) issues.push(`atlas sheet absent: ${sp.atlas.sheet}`);
    if (!existsSync(mapAbs)) issues.push(`atlas map absent: ${sp.atlas.map}`);
    else {
      const layout = JSON.parse(readFileSync(mapAbs, "utf8"));
      if ((layout.placements || []).length !== sp.atlas.sprite_count) {
        issues.push(`atlas map covers ${layout.placements?.length} sprites, store_pass says ${sp.atlas.sprite_count}`);
      }
    }
  }

  // 3. size budget passes
  if (sp.size_budget && sp.size_budget.pass !== true) issues.push(`size budget fails: ${sp.size_budget.total_bytes} > ${sp.size_budget.budget_bytes}`);

  // 4. export preset parses as a valid Godot Android preset
  if (sp.export_preset) {
    const cfgAbs = join(gamesDir, id, sp.export_preset.path);
    if (!existsSync(cfgAbs)) issues.push(`export preset absent: ${sp.export_preset.path}`);
    else {
      const parsed = parsePresetCfg(readFileSync(cfgAbs, "utf8"));
      if (parsed["preset.0"]?.platform !== "Android") issues.push(`export preset platform is not Android`);
    }
  }

  // 5. both polish passes present (A/B confirmation is the human gate -- reported, not asserted here)
  const bothPasses = Boolean(m.asset_pass) && Boolean(m.audio_pass);
  return { id, issues, file_checks_pass: issues.length === 0, both_passes_present: bothPasses, status: m.status };
}

async function cli(argv) {
  const [cmd, ...rest] = argv;
  if (cmd === "--check") {
    const [id] = rest;
    if (!id) { console.error("usage: node tools/package.mjs --check <id>"); process.exit(2); }
    const r = verify(id);
    console.log(`package verify ${id}: file_checks=${r.file_checks_pass ? "PASS" : "FAIL"} both_passes_present=${r.both_passes_present} status=${r.status}`);
    if (r.issues.length) { console.error(r.issues.map((i) => `  - ${i}`).join("\n")); process.exit(1); }
    return;
  }
  const id = rest[0];
  if (!id) { console.error("usage: node tools/package.mjs <icons|atlas|screenshot|budget|preset|verify|--check> <id> ..."); process.exit(2); }
  switch (cmd) {
    case "icons": console.log(JSON.stringify(generateIcons(id), null, 2)); return;
    case "atlas": console.log(JSON.stringify(generateAtlas(id), null, 2)); return;
    case "screenshot": console.log(JSON.stringify(captureScreenshot(id, rest[1] || "screen-1", { frames: Number(rest[2] || 220) }), null, 2)); return;
    case "budget": console.log(JSON.stringify(budgetReport(id), null, 2)); return;
    case "preset": {
      const m = JSON.parse(readFileSync(join(REPO_ROOT, "manifests", `${id}.json`), "utf8"));
      console.log(exportPresetCfg({ id, name: m.name }));
      return;
    }
    case "verify": { const r = verify(id); console.log(JSON.stringify(r, null, 2)); if (r.issues.length) process.exit(1); return; }
    default:
      console.error("usage: node tools/package.mjs <icons|atlas|screenshot|budget|preset|verify|--check> <id> ...");
      process.exit(2);
  }
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
  cli(process.argv.slice(2)).catch((e) => { console.error(e.message); process.exit(1); });
}
