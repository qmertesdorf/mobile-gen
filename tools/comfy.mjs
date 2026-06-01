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
  "%duration%": (r) => r.duration_s
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

// Pull the first output image descriptor out of a /history entry.
function firstImage(historyEntry) {
  const outputs = historyEntry?.outputs ?? {};
  for (const nodeId of Object.keys(outputs)) {
    const imgs = outputs[nodeId]?.images;
    if (Array.isArray(imgs) && imgs.length) return imgs[0];
  }
  return null;
}

// Pull the first output audio descriptor out of a /history entry.
function firstAudio(historyEntry) {
  const outputs = historyEntry?.outputs ?? {};
  for (const nodeId of Object.keys(outputs)) {
    const clips = outputs[nodeId]?.audio;
    if (Array.isArray(clips) && clips.length) return clips[0];
  }
  return null;
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

  let image = null;
  for (let i = 0; i < maxPolls; i++) {
    const hist = await fetch(`${host}/history/${prompt_id}`);
    if (!hist.ok) {
      throw new Error(`comfy: history poll failed for prompt ${prompt_id} at ${host} (HTTP ${hist.status})`);
    }
    const body = await hist.json();
    const entry = body?.[prompt_id];
    if (entry) {
      image = firstImage(entry);
      if (image) break;
      throw new Error(`comfy: prompt ${prompt_id} finished with no image output (graph error?)`);
    }
    await sleep(pollIntervalMs);
  }
  if (!image) throw new Error(`comfy: timed out waiting for prompt ${prompt_id} after ${maxPolls} polls`);

  const params = new URLSearchParams({ filename: image.filename, subfolder: image.subfolder ?? "", type: image.type ?? "output" });
  const view = await fetch(`${host}/view?${params}`);
  if (!view.ok) {
    throw new Error(`comfy: failed to download image from ${host}/view (HTTP ${view.status})`);
  }
  const bytes = Buffer.from(await view.arrayBuffer());

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
  const tplPath = join(templatesDir, `${templateName(recipe)}.json`);
  const template = JSON.parse(readFileSync(tplPath, "utf8"));
  const workflow = injectRecipe(template, recipe);

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

  let clip = null;
  for (let i = 0; i < maxPolls; i++) {
    const hist = await fetch(`${host}/history/${prompt_id}`);
    if (!hist.ok) {
      throw new Error(`comfy: history poll failed for prompt ${prompt_id} at ${host} (HTTP ${hist.status})`);
    }
    const body = await hist.json();
    const entry = body?.[prompt_id];
    if (entry) {
      clip = firstAudio(entry);
      if (clip) break;
      throw new Error(`comfy: prompt ${prompt_id} finished with no audio output (graph error?)`);
    }
    await sleep(pollIntervalMs);
  }
  if (!clip) throw new Error(`comfy: timed out waiting for prompt ${prompt_id} after ${maxPolls} polls`);

  const params = new URLSearchParams({ filename: clip.filename, subfolder: clip.subfolder ?? "", type: clip.type ?? "output" });
  const view = await fetch(`${host}/view?${params}`);
  if (!view.ok) {
    throw new Error(`comfy: failed to download audio from ${host}/view (HTTP ${view.status})`);
  }
  const bytes = Buffer.from(await view.arrayBuffer());

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
