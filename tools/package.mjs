import { readFileSync, writeFileSync, mkdirSync, statSync, existsSync, readdirSync, copyFileSync, rmSync, openSync, readSync, closeSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join, basename } from "node:path";
import { readManifest } from "./manifest.mjs"; // single manifest-dir resolver (honors GAMEFORGE_MANIFEST_DIR)

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
  return { total_bytes: total, budget_bytes: budgetBytes, pass: total <= budgetBytes, per_file };
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

// Godot .cfg values are double-quoted, and parsePresetCfg strips quotes without
// unescaping — so an embedded quote/backslash/newline in an interpolated value
// would emit a line that Godot's own parser mis-reads or that fails to round-trip.
// Inputs here are short Claude-authored titles, so reject loudly (the honest guard)
// rather than silently corrupt the preset. Pure.
function assertCfgSafe(value, field) {
  if (typeof value === "string" && /["\\\r\n]/.test(value)) {
    throw new Error(`package: ${field} contains a character unsafe for a Godot .cfg value (double-quote, backslash, or newline): ${JSON.stringify(value)}`);
  }
  return value;
}

// Derive an Android-legal package name from a game id. Android package segments
// must be valid Java identifiers ([A-Za-z_][A-Za-z0-9_]*); our ids are hyphenated
// (creature-0001), so map any run of non-alphanumerics to "_" and ensure the
// segment starts with a letter. Pure.
export function packageNameFor(id) {
  const seg = String(id).replace(/[^A-Za-z0-9]+/g, "_");
  const safe = /^[A-Za-z]/.test(seg) ? seg : `g_${seg}`;
  return `com.gameforge.${safe}`;
}

// Generate a minimal-but-valid Godot Android export preset block. Pure.
// format: "apk" (prebuilt template, gradle off) | "aab" (requires gradle build on).
// buildType: "debug" | "release". presetIndex picks the [preset.N] section so a
// single cfg can carry both a debug-APK and a release-AAB preset.
export function exportPresetCfg({ id, name, packageName, exportPath, format = "apk", buildType = "debug", presetIndex = 0 } = {}) {
  if (!id || !name) {
    throw new Error("package: exportPresetCfg requires both { id, name }");
  }
  if (format !== "apk" && format !== "aab") {
    throw new Error(`package: exportPresetCfg format must be "apk" or "aab", got ${JSON.stringify(format)}`);
  }
  if (buildType !== "debug" && buildType !== "release") {
    throw new Error(`package: exportPresetCfg buildType must be "debug" or "release", got ${JSON.stringify(buildType)}`);
  }
  assertCfgSafe(name, "exportPresetCfg name");
  const unique = assertCfgSafe(packageName || packageNameFor(id), "exportPresetCfg packageName");
  const out = assertCfgSafe(exportPath || `build/${id}-${buildType}.${format}`, "exportPresetCfg exportPath");
  const useGradle = format === "aab"; // AAB output requires Godot's gradle build enabled
  const p = `preset.${presetIndex}`;
  return [
    `[${p}]`,
    "",
    `name="${name}"`,
    `platform="Android"`,
    "runnable=true",
    `export_filter="all_resources"`,
    `include_filter=""`,
    `exclude_filter=""`,
    `export_path="${out}"`,
    "",
    `[${p}.options]`,
    "",
    `gradle_build/use_gradle_build=${useGradle ? "true" : "false"}`,
    // export_format: 0=APK, 1=AAB. Required for AAB output — Godot keys the
    // output container off this, NOT the export_path extension. Without it a
    // .aab path is rejected with "Android APK requires the *.apk extension".
    `gradle_build/export_format=${format === "aab" ? 1 : 0}`,
    `package/unique_name="${unique}"`,
    `package/name="${name}"`,
    ""
  ].join("\n");
}

// Emit a full export_presets.cfg carrying BOTH a debug-APK preset (preset.0,
// named after the game) and a release-AAB preset (preset.1, "<name> Release").
// One file, two presets, so a single project root builds either artifact. Pure.
export function exportPresetsFile({ id, name, packageName } = {}) {
  if (!id || !name) {
    throw new Error("package: exportPresetsFile requires both { id, name }");
  }
  const debug = exportPresetCfg({ id, name, packageName, format: "apk", buildType: "debug", presetIndex: 0 });
  const release = exportPresetCfg({ id, name: `${name} Release`, packageName, format: "aab", buildType: "release", presetIndex: 1 });
  return `${debug}\n${release}`;
}

// Is the Android toolchain available? Env-driven (NOT the hardcoded SDK path) so
// it is deterministic in tests and on CI. The android-setup helper exports
// ANDROID_HOME for the session, flipping this on. Mirrors the no-GPU/no-ComfyUI
// guard posture — buildArtifact() and verifyBuildArtifact() skip when this is false.
export function androidToolchainPresent() {
  return Boolean(process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT);
}

// Pure plan for a headless Godot Android export. No SDK touched — fully unit-testable.
// debug → APK via preset "<name>"; release → AAB via preset "<name> Release"
// (the two presets exportPresetsFile() writes). Returns the spawn args + out path
// so buildArtifact() only has to prepend godotBin() and run it.
export function buildArtifactPlan({ id, name, packageName, format = "apk", buildType = "debug", gamesDir = GAMES_DIR } = {}) {
  if (!id || !name) {
    throw new Error("package: buildArtifactPlan requires both { id, name }");
  }
  if (format !== "apk" && format !== "aab") {
    throw new Error(`package: buildArtifactPlan format must be "apk" or "aab", got ${JSON.stringify(format)}`);
  }
  if (buildType !== "debug" && buildType !== "release") {
    throw new Error(`package: buildArtifactPlan buildType must be "debug" or "release", got ${JSON.stringify(buildType)}`);
  }
  const preset = buildType === "debug" ? name : `${name} Release`;
  const flag = buildType === "debug" ? "--export-debug" : "--export-release";
  const projectDir = join(gamesDir, id);
  const outPath = join(projectDir, "build", `${id}-${buildType}.${format}`);
  return {
    args: ["--headless", "--path", projectDir, flag, preset, outPath],
    outPath,
    package: packageName || packageNameFor(id),
    preset,
    format,
    build_type: buildType
  };
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

// Canonical boot-splash dimensions for the given orientation. Portrait is the
// default; the manifest schema makes build.orientation optional (absent = portrait).
// Fresh object each call (no shared mutable singleton). Pure.
export function splashSize(orientation = "portrait") {
  return orientation === "landscape" ? { w: 1920, h: 1080 } : { w: 1080, h: 1920 };
}

// Generate the Godot project.godot [application] boot_splash block. Text, pure,
// and round-trips through parsePresetCfg — same "reviewable + diffable + parses"
// discipline as exportPresetCfg (the real boot-splash wiring rides project.godot).
export function bootSplashCfg({ image, showImage = true } = {}) {
  if (!image) throw new Error("package: bootSplashCfg requires an image path");
  assertCfgSafe(image, "bootSplashCfg image");
  return [
    "[application]",
    "",
    `application/boot_splash/show_image=${showImage ? "true" : "false"}`,
    `application/boot_splash/image="${image}"`,
    "application/boot_splash/fullsize=true",
    ""
  ].join("\n");
}

// Extract the leading "#rrggbb" from a palette entry like "#2fa6a0 sea-teal (primary)".
// Pure; returns lowercased "#rrggbb" or null.
export function parseHexLead(s) {
  if (typeof s !== "string") return null;
  const m = s.trim().match(/^#([0-9a-fA-F]{6})(?:[0-9a-fA-F]{2})?/);
  return m ? `#${m[1].toLowerCase()}` : null;
}

// Decide the two-stop vertical gradient for the icon background, in priority order:
// --bg arg ("#top,#bottom" or "#solid") > store_pass.icon_bg > asset_pass palette's
// first two hexes > neutral default. Pure (manifest is a plain object).
export function resolveIconBg({ bgArg, manifest = {} } = {}) {
  const fromSpec = (spec) => {
    if (typeof spec !== "string" || !spec.trim()) return null;
    const parts = spec.split(",").map((p) => parseHexLead(p)).filter(Boolean);
    if (parts.length === 0) return null;
    return { top: parts[0], bottom: parts[1] || parts[0] };
  };
  const fromArg = fromSpec(bgArg);
  if (fromArg) return fromArg;
  const fromManifest = fromSpec(manifest?.store_pass?.icon_bg);
  if (fromManifest) return fromManifest;
  const palette = manifest?.asset_pass?.visual_system?.palette;
  if (Array.isArray(palette)) {
    const hexes = palette.map(parseHexLead).filter(Boolean);
    if (hexes.length >= 2) return { top: hexes[0], bottom: hexes[1] };
    if (hexes.length === 1) return { top: hexes[0], bottom: hexes[0] };
  }
  return { top: "#202830", bottom: "#202830" };
}

// Map an iconSizeTable kind to how icon_compose.gd renders it.
// focal = transparent subject inside the adaptive safe zone; background = gradient
// fill; composite = focal alpha-blended over the gradient, opaque. Pure.
export function iconCompositionRole(kind) {
  switch (kind) {
    case "adaptive_fg": return "focal";
    case "adaptive_bg": return "background";
    case "launcher":
    case "play": return "composite";
    default: throw new Error(`package: iconCompositionRole: unknown kind "${kind}"`);
  }
}

// Resolve the pinned Godot binary. Set GODOT_BIN to the absolute path of your
// Godot 4.6.3 console executable; otherwise we look for `godot` on PATH.
function godotBin() {
  return process.env.GODOT_BIN || "godot";
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
  const m = readManifest(id);
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

// Render the boot splash from the icon master onto a solid background under games/<id>/store/.
// bg is "#RRGGBBAA" (the packager skill picks it from concept.theme); defaults to opaque black.
export function generateSplash(id, { gamesDir = GAMES_DIR, bg = "#000000ff", showImage = true } = {}) {
  const m = readManifest(id);
  const master = m?.store_pass?.icon_master;
  if (!master) throw new Error(`package: generateSplash needs store_pass.icon_master in manifests/${id}.json`);
  const masterAbs = join(gamesDir, id, master);
  if (!existsSync(masterAbs)) throw new Error(`package: icon master not found at ${masterAbs}`);
  const { w, h } = splashSize();
  const storeDir = join(gamesDir, id, "store");
  mkdirSync(storeDir, { recursive: true });
  const outPath = join(storeDir, "splash.png");
  const out = runGodot(["--headless", "--path", GODOT_DIR, "--script", "res://splash_render.gd", "--", masterAbs, outPath, `${w}x${h}`, bg], "splash_render");
  if (!out.includes("SPLASH_RENDER OK")) throw new Error(`package: splash_render did not report OK:\n${out}`);
  // store_pass.splash carries only {source, show_image}; boot_splash_cfg is for the skill to apply to project.godot.
  return { source: "store/splash.png", show_image: showImage, boot_splash_cfg: bootSplashCfg({ image: "res://store/splash.png", showImage }) };
}

// Source the release-signing env vars Godot reads (GODOT_ANDROID_KEYSTORE_RELEASE_*)
// from a git-ignored local config so no secret is ever committed. Returns the env
// overlay for the spawned process (empty for debug builds). Throws if a release
// build is requested without the config.
function releaseSigningEnv(buildType) {
  if (buildType !== "release") return {};
  const cfgPath = join(REPO_ROOT, "tools", "android-signing.local.json");
  if (!existsSync(cfgPath)) {
    throw new Error(`package: a release build needs signing config at ${cfgPath} (git-ignored). Create it with { "keystore_path", "keystore_user", "keystore_password" }.`);
  }
  const c = JSON.parse(readFileSync(cfgPath, "utf8"));
  for (const k of ["keystore_path", "keystore_user", "keystore_password"]) {
    if (!c[k]) throw new Error(`package: android-signing.local.json is missing "${k}"`);
  }
  return {
    GODOT_ANDROID_KEYSTORE_RELEASE_PATH: c.keystore_path,
    GODOT_ANDROID_KEYSTORE_RELEASE_USER: c.keystore_user,
    GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD: c.keystore_password
  };
}

// Build the Android artifact by spawning headless Godot. Toolchain-guarded: returns
// { skipped, reason } when ANDROID_HOME/ANDROID_SDK_ROOT is unset (CI / no-SDK),
// so this is never reached in vitest. On success returns the build_artifact record.
export function buildArtifact(id, { gamesDir = GAMES_DIR, format = "apk", buildType = "debug", present = androidToolchainPresent() } = {}) {
  if (!present) {
    return { skipped: true, reason: "Android toolchain absent (ANDROID_HOME/ANDROID_SDK_ROOT unset) — skipping real export, same posture as no-GPU/no-ComfyUI." };
  }
  const m = readManifest(id);
  if (!m?.name) throw new Error(`package: buildArtifact needs a name in manifests/${id}.json`);
  const plan = buildArtifactPlan({ id, name: m.name, format, buildType, gamesDir });
  mkdirSync(join(gamesDir, id, "build"), { recursive: true });
  const env = { ...process.env, ...releaseSigningEnv(buildType) };
  try {
    execFileSync(godotBin(), plan.args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], env });
  } catch (e) {
    const out = `${e.stdout ?? ""}${e.stderr ?? ""}`;
    throw new Error(`package: Godot ${buildType} ${format} export failed: ${out || e.message}`);
  }
  if (!existsSync(plan.outPath)) {
    throw new Error(`package: Godot reported success but no artifact at ${plan.outPath}`);
  }
  const bytes = statSync(plan.outPath).size;
  return {
    format: plan.format,
    build_type: plan.build_type,
    path: plan.outPath.slice(join(gamesDir, id).length + 1).replace(/\\/g, "/"),
    bytes,
    package: plan.package
  };
}

// Assert a recorded build_artifact's real file exists and is a well-formed ZIP
// (APK and AAB are both ZIP containers — first 4 bytes are PK\x03\x04). Guarded:
// skips when the toolchain is absent (binaries are git-ignored, not on CI).
export function verifyBuildArtifact(id, { gamesDir = GAMES_DIR, build_artifact, present = androidToolchainPresent() } = {}) {
  if (!present) return { skipped: true, reason: "toolchain absent — build artifact not checked" };
  const ba = build_artifact || readManifest(id)?.store_pass?.build_artifact;
  const issues = [];
  if (!ba) return { ok: false, issues: ["no build_artifact recorded in store_pass"] };
  const abs = join(gamesDir, id, ba.path);
  if (!existsSync(abs)) {
    issues.push(`build artifact absent: ${ba.path} (not found at ${abs})`);
    return { ok: false, issues, signature_ok: false };
  }
  const bytes = statSync(abs).size;
  if (bytes < 1024) issues.push(`build artifact suspiciously small: ${bytes} bytes`);
  const head = Buffer.alloc(4);
  const fd = openSync(abs, "r");
  try { readSync(fd, head, 0, 4, 0); } finally { closeSync(fd); }
  const signature_ok = head.equals(Buffer.from([0x50, 0x4b, 0x03, 0x04]));
  if (!signature_ok) issues.push(`build artifact is not a ZIP (bad signature, not an APK/AAB): ${ba.path}`);
  return { ok: issues.length === 0, issues, signature_ok, bytes };
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
export function verify(id, { gamesDir = GAMES_DIR, manifest } = {}) {
  const m = manifest || readManifest(id);
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
        issues.push(`atlas map covers ${(layout.placements || []).length} sprites, store_pass says ${sp.atlas.sprite_count}`);
      }
    }
  }

  // 2b. splash, if recorded, exists at the canonical boot-splash dimensions
  if (sp.splash) {
    const splashAbs = join(gamesDir, id, sp.splash.source);
    if (!existsSync(splashAbs)) issues.push(`splash absent: ${sp.splash.source}`);
    else {
      const { w, h } = pngSize(readFileSync(splashAbs));
      const want = splashSize();
      if (w !== want.w || h !== want.h) issues.push(`splash is ${w}x${h}, expected ${want.w}x${want.h}`);
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

  // 6. build artifact record (shape only — the real file is git-ignored and
  // checked by verifyBuildArtifact() when the toolchain is present).
  if (sp.build_artifact) {
    const ba = sp.build_artifact;
    if (ba.format !== "apk" && ba.format !== "aab") issues.push(`build_artifact.format is "${ba.format}", expected apk|aab`);
    if (ba.build_type !== "debug" && ba.build_type !== "release") issues.push(`build_artifact.build_type is "${ba.build_type}", expected debug|release`);
    if (typeof ba.path !== "string" || !ba.path) issues.push(`build_artifact.path is missing`);
  }

  return { id, issues, file_checks_pass: issues.length === 0, both_passes_present: bothPasses, status: m.status };
}

const USAGE = "usage: node tools/package.mjs <icons|atlas|screenshot|splash|budget|preset|build|verify|verify-build|--check> <id> ...";

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
  if (!id) { console.error(USAGE); process.exit(2); }
  switch (cmd) {
    case "icons": console.log(JSON.stringify(generateIcons(id), null, 2)); return;
    case "atlas": console.log(JSON.stringify(generateAtlas(id), null, 2)); return;
    case "screenshot": console.log(JSON.stringify(captureScreenshot(id, rest[1] || "screen-1", { frames: Number(rest[2] || 220) }), null, 2)); return;
    case "splash": console.log(JSON.stringify(generateSplash(id, { bg: rest[1] || "#000000ff" }), null, 2)); return;
    case "budget": console.log(JSON.stringify(budgetReport(id), null, 2)); return;
    case "preset": {
      const m = readManifest(id);
      console.log(exportPresetCfg({ id, name: m.name }));
      return;
    }
    case "build": {
      const format = rest.includes("--aab") ? "aab" : "apk";
      const buildType = rest.includes("--release") ? "release" : "debug";
      const r = buildArtifact(id, { format, buildType });
      console.log(JSON.stringify(r, null, 2));
      if (r.skipped) process.exit(3); // distinct code: "toolchain absent", not a failure
      return;
    }
    case "verify-build": {
      const r = verifyBuildArtifact(id);
      console.log(JSON.stringify(r, null, 2));
      if (r.skipped) return;
      if (!r.ok) process.exit(1);
      return;
    }
    case "verify": { const r = verify(id); console.log(JSON.stringify(r, null, 2)); if (r.issues.length) process.exit(1); return; }
    default:
      console.error(USAGE);
      process.exit(2);
  }
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
  cli(process.argv.slice(2)).catch((e) => { console.error(e.message); process.exit(1); });
}
