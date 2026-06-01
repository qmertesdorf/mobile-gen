import { test, expect, describe } from "vitest";
import { injectRecipe } from "./comfy.mjs";

// A tiny stand-in for an exported ComfyUI graph: nodes keyed by id, each with
// class_type + inputs. Placeholder tokens are plain strings like "%prompt%".
function fixtureTemplate() {
  return {
    "4": { class_type: "CheckpointLoaderSimple", inputs: { ckpt_name: "%checkpoint%" } },
    "6": { class_type: "CLIPTextEncode", inputs: { text: "%prompt%", clip: ["4", 1] } },
    "7": { class_type: "CLIPTextEncode", inputs: { text: "%negative%", clip: ["4", 1] } },
    "5": { class_type: "EmptyLatentImage", inputs: { width: "%width%", height: "%height%", batch_size: 1 } },
    "3": {
      class_type: "KSampler",
      inputs: {
        seed: "%seed%", steps: "%steps%", cfg: "%cfg%", sampler_name: "%sampler%",
        model: ["4", 0], positive: ["6", 0], negative: ["7", 0], latent_image: ["5", 0]
      }
    },
    "9": { class_type: "SaveImage", inputs: { images: ["8", 0] } }
  };
}

function fullRecipe() {
  return {
    name: "hero",
    checkpoint: "dreamshaperXL.safetensors",
    prompt: "a small round forest spirit",
    negative: "logo, watermark, text",
    seed: 123456,
    sampler: "dpmpp_2m",
    steps: 30,
    cfg: 6.5,
    master_resolution: 512,
    layerdiffuse: true
  };
}

describe("injectRecipe", () => {
  test("replaces scalar placeholders with recipe values (master_resolution → width & height)", () => {
    const out = injectRecipe(fixtureTemplate(), fullRecipe());
    expect(out["4"].inputs.ckpt_name).toBe("dreamshaperXL.safetensors");
    expect(out["6"].inputs.text).toBe("a small round forest spirit");
    expect(out["7"].inputs.text).toBe("logo, watermark, text");
    expect(out["5"].inputs.width).toBe(512);
    expect(out["5"].inputs.height).toBe(512);
    expect(out["3"].inputs.seed).toBe(123456);
    expect(out["3"].inputs.steps).toBe(30);
    expect(out["3"].inputs.cfg).toBe(6.5);
    expect(out["3"].inputs.sampler_name).toBe("dpmpp_2m");
  });

  test("leaves non-placeholder values (wiring arrays, literals) untouched", () => {
    const out = injectRecipe(fixtureTemplate(), fullRecipe());
    expect(out["6"].inputs.clip).toEqual(["4", 1]);
    expect(out["5"].inputs.batch_size).toBe(1);
    expect(out["9"].inputs.images).toEqual(["8", 0]);
    expect(out["3"].class_type).toBe("KSampler");
  });

  test("does not mutate the input template", () => {
    const tpl = fixtureTemplate();
    injectRecipe(tpl, fullRecipe());
    expect(tpl["6"].inputs.text).toBe("%prompt%");
    expect(tpl["5"].inputs.width).toBe("%width%");
  });

  test("throws a clear error when a required field is missing", () => {
    const r = fullRecipe();
    delete r.prompt;
    expect(() => injectRecipe(fixtureTemplate(), r)).toThrow(/prompt/);
  });

  test("throws when the template uses %lora% but the recipe omits lora (templates without a LoRA must omit the token)", () => {
    const tpl = { "10": { class_type: "LoraLoader", inputs: { lora_name: "%lora%" } } };
    const r = fullRecipe(); // has no `lora` key
    expect(() => injectRecipe(tpl, r)).toThrow(/%lora%|lora/);
  });

  test("fills %duration% from duration_s for audio recipes", () => {
    const tpl = { "1": { class_type: "EmptyLatentAudio", inputs: { seconds: "%duration%" } },
                  "2": { class_type: "CLIPTextEncode", inputs: { text: "%prompt%" } } };
    const recipe = { kind: "music", prompt: "calm ambient pad", duration_s: 30 };
    const out = injectRecipe(tpl, recipe);
    expect(out["1"].inputs.seconds).toBe(30);
    expect(out["2"].inputs.text).toBe("calm ambient pad");
  });
});

import { check, gen } from "./comfy.mjs";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join as pjoin } from "node:path";

// Build a fake fetch that routes by method+path and records calls. Each route
// value is either a response spec or a function(callIndex) returning one, so a
// route can change across polls. A response spec mimics the slice of the fetch
// Response API the tool uses: { ok, status, json(), arrayBuffer() }.
function mockFetch(routes) {
  const calls = [];
  const counts = {};
  const fn = async (url, opts = {}) => {
    const method = (opts.method || "GET").toUpperCase();
    const path = new URL(url).pathname;
    const key = `${method} ${path}`;
    calls.push({ key, url, opts });
    const route = routes[key];
    if (route === undefined) throw new Error(`unrouted ${key}`);
    const idx = counts[key] = (counts[key] ?? 0) + 1;
    const spec = typeof route === "function" ? route(idx) : route;
    if (spec instanceof Error) throw spec;
    return {
      ok: spec.ok ?? true,
      status: spec.status ?? 200,
      async json() { return spec.body; },
      async arrayBuffer() { return spec.bytes ?? new ArrayBuffer(0); }
    };
  };
  fn.calls = calls;
  return fn;
}

describe("check", () => {
  test("reports reachable + the available checkpoints", async () => {
    const fetch = mockFetch({
      "GET /system_stats": { body: { system: {} } },
      "GET /object_info/CheckpointLoaderSimple": {
        body: { CheckpointLoaderSimple: { input: { required: { ckpt_name: [["a.safetensors", "b.safetensors"]] } } } }
      }
    });
    const res = await check({ fetch, host: "http://127.0.0.1:8188" });
    expect(res.reachable).toBe(true);
    expect(res.checkpoints).toEqual(["a.safetensors", "b.safetensors"]);
  });

  test("reports unreachable when the connection is refused", async () => {
    const fetch = mockFetch({ "GET /system_stats": new Error("ECONNREFUSED") });
    const res = await check({ fetch, host: "http://127.0.0.1:8188" });
    expect(res.reachable).toBe(false);
    expect(res.error).toMatch(/ECONNREFUSED/);
  });
});

describe("gen", () => {
  const recipe = () => ({
    name: "hero", checkpoint: "a.safetensors", prompt: "a forest spirit",
    negative: "logo, text", seed: 7, sampler: "dpmpp_2m", steps: 30, cfg: 6.5,
    master_resolution: 512, layerdiffuse: true
  });

  async function withDirs(run) {
    const templatesDir = mkdtempSync(pjoin(tmpdir(), "cf-tpl-"));
    const gamesDir = mkdtempSync(pjoin(tmpdir(), "cf-games-"));
    writeFileSync(pjoin(templatesDir, "sdxl-layerdiffuse.json"), JSON.stringify({
      "6": { class_type: "CLIPTextEncode", inputs: { text: "%prompt%" } },
      "9": { class_type: "SaveImage", inputs: { images: ["8", 0] } }
    }));
    try { return await run({ templatesDir, gamesDir }); }
    finally { rmSync(templatesDir, { recursive: true, force: true }); rmSync(gamesDir, { recursive: true, force: true }); }
  }

  const HISTORY_DONE = {
    body: { abc: { outputs: { "9": { images: [{ filename: "ComfyUI_0001.png", subfolder: "", type: "output" }] } } } }
  };

  test("happy path: submits, polls, downloads, writes the PNG", async () => {
    await withDirs(async ({ templatesDir, gamesDir }) => {
      const fetch = mockFetch({
        "POST /prompt": { body: { prompt_id: "abc" } },
        "GET /history/abc": HISTORY_DONE,
        "GET /view": { bytes: new TextEncoder().encode("PNGDATA").buffer }
      });
      const res = await gen("creature-0001", "hero", recipe(), { fetch, templatesDir, gamesDir, pollIntervalMs: 0 });
      const outPath = pjoin(gamesDir, "creature-0001", "art", "hero.png");
      expect(existsSync(outPath)).toBe(true);
      expect(readFileSync(outPath, "utf8")).toBe("PNGDATA");
      expect(res.prompt_id).toBe("abc");
      expect(res.path).toBe(outPath);
    });
  });

  test("polls /history until the result appears", async () => {
    await withDirs(async ({ templatesDir, gamesDir }) => {
      const fetch = mockFetch({
        "POST /prompt": { body: { prompt_id: "abc" } },
        "GET /history/abc": (n) => (n < 3 ? { body: {} } : HISTORY_DONE),
        "GET /view": { bytes: new TextEncoder().encode("PNGDATA").buffer }
      });
      await gen("creature-0001", "hero", recipe(), { fetch, templatesDir, gamesDir, pollIntervalMs: 0 });
      const historyCalls = fetch.calls.filter((c) => c.key === "GET /history/abc").length;
      expect(historyCalls).toBe(3);
    });
  });

  test("throws on a graph error and writes no file", async () => {
    await withDirs(async ({ templatesDir, gamesDir }) => {
      const fetch = mockFetch({
        "POST /prompt": { ok: false, status: 400, body: { error: { message: "node 6 missing input" }, node_errors: {} } }
      });
      await expect(gen("creature-0001", "hero", recipe(), { fetch, templatesDir, gamesDir, pollIntervalMs: 0 }))
        .rejects.toThrow(/graph error|node 6/);
      expect(existsSync(pjoin(gamesDir, "creature-0001", "art", "hero.png"))).toBe(false);
    });
  });

  test("throws with the host when ComfyUI is unreachable", async () => {
    await withDirs(async ({ templatesDir, gamesDir }) => {
      const fetch = mockFetch({ "POST /prompt": new Error("ECONNREFUSED") });
      await expect(gen("creature-0001", "hero", recipe(),
        { fetch, host: "http://127.0.0.1:8188", templatesDir, gamesDir, pollIntervalMs: 0 }))
        .rejects.toThrow(/127\.0\.0\.1:8188|unreachable/);
      expect(existsSync(pjoin(gamesDir, "creature-0001", "art", "hero.png"))).toBe(false);
    });
  });

  test("throws and writes no file when /view download fails", async () => {
    await withDirs(async ({ templatesDir, gamesDir }) => {
      const fetch = mockFetch({
        "POST /prompt": { body: { prompt_id: "abc" } },
        "GET /history/abc": HISTORY_DONE,
        "GET /view": { ok: false, status: 404 }
      });
      await expect(gen("creature-0001", "hero", recipe(), { fetch, templatesDir, gamesDir, pollIntervalMs: 0 }))
        .rejects.toThrow(/view|404/);
      expect(existsSync(pjoin(gamesDir, "creature-0001", "art", "hero.png"))).toBe(false);
    });
  });
});

import { templateName } from "./comfy.mjs";

describe("templateName", () => {
  test("non-layerdiffuse recipe → sdxl", () => {
    expect(templateName({ layerdiffuse: false })).toBe("sdxl");
  });
  test("layerdiffuse without lora → sdxl-layerdiffuse", () => {
    expect(templateName({ layerdiffuse: true })).toBe("sdxl-layerdiffuse");
  });
  test("layerdiffuse with lora → sdxl-layerdiffuse-lora", () => {
    expect(templateName({ layerdiffuse: true, lora: "pixel-art-xl.safetensors" })).toBe("sdxl-layerdiffuse-lora");
  });
  test("sfx recipe → stable-audio", () => {
    expect(templateName({ kind: "sfx" })).toBe("stable-audio");
  });
  test("music recipe → stable-audio", () => {
    expect(templateName({ kind: "music" })).toBe("stable-audio");
  });
  test("image recipe (no kind) still selects an image template", () => {
    expect(templateName({ layerdiffuse: false })).toBe("sdxl");
  });
});
