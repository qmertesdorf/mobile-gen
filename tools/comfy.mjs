import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

export const COMFY_HOST = process.env.COMFY_HOST || "http://127.0.0.1:8188";
export const TEMPLATES_DIR = process.env.GAMEFORGE_COMFY_TEMPLATES || join(__dirname, "comfy-templates");
export const GAMES_DIR = process.env.GAMEFORGE_GAMES_DIR || join(REPO_ROOT, "games");

// Map a %token% to the recipe field that fills it. master_resolution fills the
// square master's width AND height. A resolver returning undefined is a hard
// error so a missing field fails loudly (attributable to the recipe), never
// silently leaving a literal "%prompt%" in the graph.
const TOKENS = {
  "%checkpoint%": (r) => r.checkpoint,
  "%prompt%": (r) => r.prompt,
  "%negative%": (r) => r.negative ?? "",
  "%seed%": (r) => r.seed,
  "%steps%": (r) => r.steps,
  "%cfg%": (r) => r.cfg,
  "%sampler%": (r) => r.sampler,
  "%width%": (r) => r.master_resolution,
  "%height%": (r) => r.master_resolution,
  "%lora%": (r) => r.lora,
  "%duration%": (r) => r.duration_s // audio clip length; token name ≠ field (duration_s)
};

// Deep-clone `template` and substitute placeholder strings with recipe values.
// Pure: no network, no disk, no mutation of the input.
export function injectRecipe(template, recipe) {
  const walk = (node) => {
    if (Array.isArray(node)) return node.map(walk);
    if (node && typeof node === "object") {
      const out = {};
      for (const [k, v] of Object.entries(node)) out[k] = walk(v);
      return out;
    }
    if (typeof node === "string" && Object.prototype.hasOwnProperty.call(TOKENS, node)) {
      const value = TOKENS[node](recipe);
      if (value === undefined) {
        throw new Error(`comfy: recipe is missing the field for placeholder ${node}`);
      }
      return value;
    }
    return node;
  };
  return walk(template);
}

// ---- WAV post-process seam (SFX envelope) -------------------------------
// Stable Audio Open (via the soundfile-WAV patch on the pinned torch 2.11 stack)
// emits 16-bit PCM WAV. These helpers decode that to per-channel float, apply the
// SFX envelope the A/B-round-3 probe locked in, and re-encode. Pure: Buffer in,
// Buffer out — no disk, no network, no input mutation (slice() copies). The
// envelope (trim-to-event → loudness-normalize → fades) is what turns a raw SAO
// clip from "explosive / too quiet" into a clean, perceptibly-loud one-shot.
// Evidence + the validated prototype: docs/superpowers/2026-06-02-audio-art-probe-results.md.

export function decodeWav(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 12 ||
      buf.toString("latin1", 0, 4) !== "RIFF" || buf.toString("latin1", 8, 12) !== "WAVE") {
    throw new Error("comfy: decodeWav: not a RIFF/WAVE file");
  }
  if (buf.length < 44) {
    throw new Error("comfy: decodeWav requires a WAV buffer of at least 44 bytes");
  }
  let off = 12, channels = 0, sampleRate = 0, bitDepth = 0, fmtCode = 0, dataOff = 0, dataLen = 0;
  while (off + 8 <= buf.length) {
    const id = buf.toString("latin1", off, off + 4);
    const sz = buf.readUInt32LE(off + 4);
    if (id === "fmt ") {
      fmtCode = buf.readUInt16LE(off + 8);
      channels = buf.readUInt16LE(off + 10);
      sampleRate = buf.readUInt32LE(off + 12);
      bitDepth = buf.readUInt16LE(off + 22);
    } else if (id === "data") {
      dataOff = off + 8; dataLen = sz;
    }
    off += 8 + sz + (sz & 1); // chunks are word-aligned
  }
  if (fmtCode !== 1 || bitDepth !== 16) {
    throw new Error(`comfy: decodeWav supports 16-bit PCM only (got format ${fmtCode}, ${bitDepth}-bit) — the SFX envelope seam assumes the Stable Audio Open soundfile-WAV output`);
  }
  if (!dataOff || channels < 1) throw new Error("comfy: decodeWav: missing fmt/data chunk");
  if (dataOff + dataLen > buf.length) throw new Error("comfy: decodeWav: data chunk declares more bytes than the file holds (truncated WAV)");
  const frames = Math.floor(dataLen / 2 / channels);
  const samples = [];
  for (let c = 0; c < channels; c++) samples.push(new Float32Array(frames));
  for (let i = 0; i < frames; i++) {
    for (let c = 0; c < channels; c++) {
      // /32767 is symmetric with encodeWav's *32767 so the round-trip is lossless within int16
      // quantization (the most-negative −32768 simply clamps back to −1 on re-encode — a 1-LSB,
      // inaudible edge case); do NOT change to /32768 without revisiting that symmetry.
      samples[c][i] = buf.readInt16LE(dataOff + (i * channels + c) * 2) / 32767;
    }
  }
  return { channels, sampleRate, bitDepth, samples };
}

export function encodeWav(channels, sampleRate, samples) {
  const frames = samples[0].length;
  const dataBytes = frames * channels * 2;
  const buf = Buffer.alloc(44 + dataBytes);
  buf.write("RIFF", 0, "latin1"); buf.writeUInt32LE(36 + dataBytes, 4); buf.write("WAVE", 8, "latin1");
  buf.write("fmt ", 12, "latin1"); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(channels, 22);
  buf.writeUInt32LE(sampleRate, 24); buf.writeUInt32LE(sampleRate * channels * 2, 28);
  buf.writeUInt16LE(channels * 2, 32); buf.writeUInt16LE(16, 34);
  buf.write("data", 36, "latin1"); buf.writeUInt32LE(dataBytes, 40);
  let p = 44;
  for (let i = 0; i < frames; i++) {
    for (let c = 0; c < channels; c++) {
      const v = Math.max(-1, Math.min(1, samples[c][i]));
      buf.writeInt16LE(Math.round(v * 32767), p); p += 2;
    }
  }
  return buf;
}

// trim-to-event → loudness-normalize (RMS target + peak clamp) → fade-in/out.
// Defaults are the round-3 locked values. Pure.
export function envelopeSfxWav(buf, { targetRms = 0.13, peak = 0.97, fadeInMs = 6, fadeOutMs = 40, eventDb = -32, padMs = 8 } = {}) {
  const { channels, sampleRate, samples } = decodeWav(buf);
  const n = samples[0].length;
  // 1. event bounds on the ORIGINAL signal, threshold relative to its own peak.
  let peak0 = 0;
  for (let c = 0; c < channels; c++) for (let i = 0; i < n; i++) peak0 = Math.max(peak0, Math.abs(samples[c][i]));
  const thr = peak0 * Math.pow(10, eventDb / 20);
  let first = -1, last = 0;
  for (let i = 0; i < n; i++) {
    let m = 0;
    for (let c = 0; c < channels; c++) m = Math.max(m, Math.abs(samples[c][i]));
    if (m > thr) { if (first < 0) first = i; last = i; }
  }
  if (first < 0) first = 0;
  const pad = Math.floor((sampleRate * padMs) / 1000);
  const start = Math.max(0, first - pad), end = Math.min(n, last + pad + 1);
  const out = [];
  for (let c = 0; c < channels; c++) out.push(samples[c].slice(start, end)); // slice() copies → input untouched
  const len = out[0].length;
  // 2. loudness-normalize to targetRms, then clamp peak.
  let sumsq = 0, cnt = 0;
  for (let c = 0; c < channels; c++) for (let i = 0; i < len; i++) { sumsq += out[c][i] * out[c][i]; cnt++; }
  const rms = Math.sqrt(sumsq / cnt);
  let gain = rms > 0 ? targetRms / rms : 1;
  let pk = 0;
  for (let c = 0; c < channels; c++) for (let i = 0; i < len; i++) pk = Math.max(pk, Math.abs(out[c][i] * gain));
  if (pk > peak) gain *= peak / pk;
  // 3. fades, applied on top of the gain.
  const fi = Math.floor((sampleRate * fadeInMs) / 1000), fo = Math.floor((sampleRate * fadeOutMs) / 1000);
  for (let c = 0; c < channels; c++) {
    for (let i = 0; i < len; i++) {
      let g = gain;
      if (fi > 0 && i < fi) g *= i / fi;
      if (fo > 0 && i >= len - fo) g *= (len - 1 - i) / fo;
      out[c][i] *= g;
    }
  }
  return encodeWav(channels, sampleRate, out);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Ping ComfyUI and list installed checkpoints. Never throws on a down server —
// returns { reachable:false, error } so --check can report it cleanly.
export async function check({ fetch = globalThis.fetch, host = COMFY_HOST } = {}) {
  try {
    const stats = await fetch(`${host}/system_stats`);
    if (!stats.ok) return { reachable: false, host, error: `system_stats HTTP ${stats.status}` };
    const info = await fetch(`${host}/object_info/CheckpointLoaderSimple`);
    if (!info.ok) return { reachable: false, host, error: `object_info HTTP ${info.status}` };
    const body = await info.json();
    const checkpoints = body?.CheckpointLoaderSimple?.input?.required?.ckpt_name?.[0] ?? [];
    return { reachable: true, host, checkpoints };
  } catch (e) {
    return { reachable: false, host, error: String(e.message ?? e) };
  }
}

// Select the workflow template. layerdiffuse picks the RGBA graph; a recipe
// that also names a `lora` picks the LoRA-aware variant (which carries a
// LoraLoader + %lora% token) so per-game style profiles can swap a LoRA.
function templateName(recipe) {
  if (recipe.kind === "sfx" || recipe.kind === "music") return "stable-audio";
  if (!recipe.layerdiffuse) return "sdxl";
  return recipe.lora ? "sdxl-layerdiffuse-lora" : "sdxl-layerdiffuse";
}

export { templateName };

// Build a /history-entry picker for a given output kind ("images"/"audio").
// Returns the first descriptor found. Our templates each carry exactly ONE save
// node (one SaveImage or one SaveAudio) and no preview nodes, so /history holds a
// single output node and "first" is unambiguous — keep that invariant if a
// template ever gains a second/preview save node, or select by save-node id here.
const firstOutput = (kind) => (historyEntry) => {
  const outputs = historyEntry?.outputs ?? {};
  for (const nodeId of Object.keys(outputs)) {
    const arr = outputs[nodeId]?.[kind];
    if (Array.isArray(arr) && arr.length) return arr[0];
  }
  return null;
};

const firstImage = firstOutput("images");
const firstAudio = firstOutput("audio");

// Shared ComfyUI flow: submit a workflow graph, poll for completion, download
// the output bytes. Returns { bytes, prompt_id } on success; throws loudly on
// every failure so callers get full host/graph context. All options are
// required by design — the public gen()/genAudio() callers own the defaults
// (host, polling, maxPolls) and supply pick/label; this private helper has none.
async function runGraph(workflow, { fetch, host, pollIntervalMs, maxPolls, pick, label }) {
  let submit;
  try {
    submit = await fetch(`${host}/prompt`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prompt: workflow })
    });
  } catch (e) {
    throw new Error(`comfy: ComfyUI unreachable at ${host} (${String(e.message ?? e)}) — start the server or set COMFY_HOST`);
  }
  if (!submit.ok) {
    const err = await submit.json().catch(() => ({}));
    throw new Error(`comfy: graph error from ${host}/prompt (HTTP ${submit.status}): ${JSON.stringify(err.error ?? err)}`);
  }
  const { prompt_id } = await submit.json();

  let output = null;
  for (let i = 0; i < maxPolls; i++) {
    const hist = await fetch(`${host}/history/${prompt_id}`);
    if (!hist.ok) {
      throw new Error(`comfy: history poll failed for prompt ${prompt_id} at ${host} (HTTP ${hist.status})`);
    }
    const body = await hist.json();
    const entry = body?.[prompt_id];
    if (entry) {
      output = pick(entry);
      if (output) break;
      throw new Error(`comfy: prompt ${prompt_id} finished with no ${label} output (graph error?)`);
    }
    await sleep(pollIntervalMs);
  }
  if (!output) throw new Error(`comfy: timed out waiting for prompt ${prompt_id} after ${maxPolls} polls`);

  const params = new URLSearchParams({ filename: output.filename, subfolder: output.subfolder ?? "", type: output.type ?? "output" });
  const view = await fetch(`${host}/view?${params}`);
  if (!view.ok) {
    throw new Error(`comfy: failed to download ${label} from ${host}/view (HTTP ${view.status})`);
  }
  const bytes = Buffer.from(await view.arrayBuffer());
  return { bytes, prompt_id };
}

// Turn a recipe into a committed RGBA PNG at games/<id>/art/<name>.png.
// Fails loudly (with host/graph context) so any failure is attributable to infra.
export async function gen(id, name, recipe, {
  fetch = globalThis.fetch,
  host = COMFY_HOST,
  templatesDir = TEMPLATES_DIR,
  gamesDir = GAMES_DIR,
  pollIntervalMs = 1000,
  maxPolls = 1800 // ~30 min ceiling: an 8GB card offloads SDXL+LayerDiffuse and a
                  // 1024² master can take 8-12 min; 10 min was too tight. 16GB is far faster.
} = {}) {
  const tplPath = join(templatesDir, `${templateName(recipe)}.json`);
  const template = JSON.parse(readFileSync(tplPath, "utf8"));
  const workflow = injectRecipe(template, recipe);

  const { bytes, prompt_id } = await runGraph(workflow, { fetch, host, pollIntervalMs, maxPolls, pick: firstImage, label: "image" });

  const artDir = join(gamesDir, id, "art");
  mkdirSync(artDir, { recursive: true });
  const outPath = join(artDir, `${name}.png`);
  writeFileSync(outPath, bytes);
  return { path: outPath, prompt_id };
}

// Turn an audio recipe into a committed clip at games/<id>/audio/<name>.<format>.
// Fails loudly (with host/graph context) so any failure is attributable to infra.
export async function genAudio(id, name, recipe, {
  fetch = globalThis.fetch,
  host = COMFY_HOST,
  templatesDir = TEMPLATES_DIR,
  gamesDir = GAMES_DIR,
  pollIntervalMs = 1000,
  maxPolls = 600 // audio gen is far cheaper than a 1024² image master
} = {}) {
  if (!recipe.format) {
    throw new Error(`comfy: genAudio recipe for '${name}' is missing required field 'format' (expected "wav" or "ogg")`);
  }
  const tplPath = join(templatesDir, `${templateName(recipe)}.json`);
  const template = JSON.parse(readFileSync(tplPath, "utf8"));
  const workflow = injectRecipe(template, recipe);

  const { bytes, prompt_id } = await runGraph(workflow, { fetch, host, pollIntervalMs, maxPolls, pick: firstAudio, label: "audio" });

  const audioDir = join(gamesDir, id, "audio");
  mkdirSync(audioDir, { recursive: true });
  const outPath = join(audioDir, `${name}.${recipe.format}`);
  writeFileSync(outPath, bytes);
  return { path: outPath, prompt_id };
}

async function cli(argv) {
  const [cmd, ...rest] = argv;
  if (cmd === "--check") {
    const res = await check();
    if (res.reachable) {
      console.log(`comfy OK at ${res.host} — ${res.checkpoints.length} checkpoint(s): ${res.checkpoints.join(", ")}`);
    } else {
      console.error(`comfy UNREACHABLE at ${res.host}: ${res.error}`);
      process.exit(1);
    }
    return;
  }
  if (cmd === "gen") {
    const [id, name, recipeJson] = rest;
    if (!id || !name || !recipeJson) {
      console.error("usage: node tools/comfy.mjs gen <id> <asset-name> '<recipe-json>'");
      process.exit(2);
    }
    const res = await gen(id, name, JSON.parse(recipeJson));
    console.log(`wrote ${res.path} (prompt ${res.prompt_id})`);
    return;
  }
  if (cmd === "gen-audio") {
    const [id, name, recipeJson] = rest;
    if (!id || !name || !recipeJson) {
      console.error("usage: node tools/comfy.mjs gen-audio <id> <clip-name> '<recipe-json>'");
      process.exit(2);
    }
    const res = await genAudio(id, name, JSON.parse(recipeJson));
    console.log(`wrote ${res.path} (prompt ${res.prompt_id})`);
    return;
  }
  console.error("usage: node tools/comfy.mjs <--check | gen <id> <asset-name> '<recipe-json>' | gen-audio <id> <clip-name> '<recipe-json>'>");
  process.exit(2);
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
  cli(process.argv.slice(2)).catch((e) => { console.error(e.message); process.exit(1); });
}
