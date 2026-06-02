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
    const tpl = {
      "1": { class_type: "EmptyLatentAudio", inputs: { seconds: "%duration%" } },
      "2": { class_type: "CLIPTextEncode", inputs: { text: "%prompt%" } }
    };
    const recipe = { kind: "music", prompt: "calm ambient pad", duration_s: 30 };
    const out = injectRecipe(tpl, recipe);
    expect(out["1"].inputs.seconds).toBe(30);
    expect(out["2"].inputs.text).toBe("calm ambient pad");
  });

  test("throws when the template uses %duration% but the recipe omits duration_s", () => {
    const tpl = { "1": { class_type: "EmptyLatentAudio", inputs: { seconds: "%duration%" } } };
    expect(() => injectRecipe(tpl, { kind: "music", prompt: "x" })).toThrow(/%duration%|duration/);
  });

  test("fills %scheduler% from recipe.scheduler, defaulting to normal when omitted", () => {
    const tpl = { "3": { class_type: "KSampler", inputs: { scheduler: "%scheduler%" } } };
    expect(injectRecipe(tpl, { ...fullRecipe(), scheduler: "karras" })["3"].inputs.scheduler).toBe("karras");
    expect(injectRecipe(tpl, fullRecipe())["3"].inputs.scheduler).toBe("normal"); // default, like %negative%
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

import { genAudio } from "./comfy.mjs";
import { decodeWav, encodeWav, envelopeSfxWav } from "./comfy.mjs";

describe("genAudio", () => {
  const recipe = () => ({
    name: "collect", kind: "sfx", prompt: "soft chime pickup", negative: "music, voice",
    seed: 7, duration_s: 0.8, sampler: "dpmpp_3m_sde_gpu", steps: 8, cfg: 6, format: "wav",
    loop: false
  });

  async function withDirs(run) {
    const templatesDir = mkdtempSync(pjoin(tmpdir(), "cf-atpl-"));
    const gamesDir = mkdtempSync(pjoin(tmpdir(), "cf-agames-"));
    writeFileSync(pjoin(templatesDir, "stable-audio.json"), JSON.stringify({
      "6": { class_type: "CLIPTextEncode", inputs: { text: "%prompt%" } },
      "11": { class_type: "EmptyLatentAudio", inputs: { seconds: "%duration%" } },
      "12": { class_type: "SaveAudio", inputs: { audio: ["10", 0] } }
    }));
    try { return await run({ templatesDir, gamesDir }); }
    finally { rmSync(templatesDir, { recursive: true, force: true }); rmSync(gamesDir, { recursive: true, force: true }); }
  }

  const HISTORY_DONE = {
    body: { abc: { outputs: { "12": { audio: [{ filename: "ComfyUI_0001.wav", subfolder: "", type: "output" }] } } } }
  };

  test("happy path (sfx): writes an enveloped, valid WAV at games/<id>/audio/<name>.wav", async () => {
    await withDirs(async ({ templatesDir, gamesDir }) => {
      // a real 16-bit WAV with leading/trailing silence so the envelope has work to do
      const rate = 44100, n = rate; // 1 s
      const ch = new Float32Array(n);
      for (let i = 0; i < n; i++) ch[i] = (i > rate * 0.3 && i < rate * 0.6) ? 0.4 * Math.sin((2 * Math.PI * 440 * i) / rate) : 0;
      const wav = encodeWav(1, rate, [ch]);
      const fetch = mockFetch({
        "POST /prompt": { body: { prompt_id: "abc" } },
        "GET /history/abc": HISTORY_DONE,
        "GET /view": { bytes: wav.buffer.slice(wav.byteOffset, wav.byteOffset + wav.byteLength) }
      });
      const res = await genAudio("creature-0001", "collect", recipe(), { fetch, templatesDir, gamesDir, pollIntervalMs: 0 });
      const outPath = pjoin(gamesDir, "creature-0001", "audio", "collect.wav");
      expect(existsSync(outPath)).toBe(true);
      const written = decodeWav(readFileSync(outPath));   // parses → still a valid WAV
      expect(written.samples[0].length).toBeLessThan(n);  // silence trimmed → enveloped
      expect(res.path).toBe(outPath);
      expect(res.prompt_id).toBe("abc");
    });
  });

  test("uses the recipe.format extension for the music .ogg case", async () => {
    await withDirs(async ({ templatesDir, gamesDir }) => {
      const fetch = mockFetch({
        "POST /prompt": { body: { prompt_id: "abc" } },
        "GET /history/abc": HISTORY_DONE,
        "GET /view": { bytes: new TextEncoder().encode("OGGDATA").buffer }
      });
      const r = { ...recipe(), name: "bgm", kind: "music", format: "ogg", duration_s: 30, loop: true };
      const res = await genAudio("creature-0001", "bgm", r, { fetch, templatesDir, gamesDir, pollIntervalMs: 0 });
      expect(res.path).toBe(pjoin(gamesDir, "creature-0001", "audio", "bgm.ogg"));
      expect(existsSync(res.path)).toBe(true);
    });
  });

  test("music bytes are written through UNCHANGED (envelope is sfx-only)", async () => {
    await withDirs(async ({ templatesDir, gamesDir }) => {
      const fetch = mockFetch({
        "POST /prompt": { body: { prompt_id: "abc" } },
        "GET /history/abc": HISTORY_DONE,
        "GET /view": { bytes: new TextEncoder().encode("OGGDATA").buffer }
      });
      const r = { ...recipe(), name: "bgm", kind: "music", format: "ogg", duration_s: 30, loop: true };
      const res = await genAudio("creature-0001", "bgm", r, { fetch, templatesDir, gamesDir, pollIntervalMs: 0 });
      expect(readFileSync(res.path, "utf8")).toBe("OGGDATA"); // not parsed, not enveloped
    });
  });

  test("throws on a graph error and writes no file", async () => {
    await withDirs(async ({ templatesDir, gamesDir }) => {
      const fetch = mockFetch({
        "POST /prompt": { ok: false, status: 400, body: { error: { message: "node 11 missing input" } } }
      });
      await expect(genAudio("creature-0001", "collect", recipe(), { fetch, templatesDir, gamesDir, pollIntervalMs: 0 }))
        .rejects.toThrow(/graph error|node 11/);
      expect(existsSync(pjoin(gamesDir, "creature-0001", "audio", "collect.wav"))).toBe(false);
    });
  });

  test("throws and writes no file when the prompt finishes with no audio output", async () => {
    await withDirs(async ({ templatesDir, gamesDir }) => {
      const fetch = mockFetch({
        "POST /prompt": { body: { prompt_id: "abc" } },
        "GET /history/abc": { body: { abc: { outputs: { "12": {} } } } }
      });
      await expect(genAudio("creature-0001", "collect", recipe(), { fetch, templatesDir, gamesDir, pollIntervalMs: 0 }))
        .rejects.toThrow(/no audio output/);
      expect(existsSync(pjoin(gamesDir, "creature-0001", "audio", "collect.wav"))).toBe(false);
    });
  });

  test("polls /history until the result appears", async () => {
    await withDirs(async ({ templatesDir, gamesDir }) => {
      // sfx recipe requires a real WAV now that the envelope runs
      const rate = 44100, n = rate;
      const ch = new Float32Array(n);
      for (let i = 0; i < n; i++) ch[i] = (i > rate * 0.3 && i < rate * 0.6) ? 0.4 * Math.sin((2 * Math.PI * 440 * i) / rate) : 0;
      const wav = encodeWav(1, rate, [ch]);
      const fetch = mockFetch({
        "POST /prompt": { body: { prompt_id: "abc" } },
        "GET /history/abc": (n) => (n < 3 ? { body: {} } : HISTORY_DONE),
        "GET /view": { bytes: wav.buffer.slice(wav.byteOffset, wav.byteOffset + wav.byteLength) }
      });
      await genAudio("creature-0001", "collect", recipe(), { fetch, templatesDir, gamesDir, pollIntervalMs: 0 });
      const historyCalls = fetch.calls.filter((c) => c.key === "GET /history/abc").length;
      expect(historyCalls).toBe(3);
    });
  });

  test("throws with the host when ComfyUI is unreachable", async () => {
    await withDirs(async ({ templatesDir, gamesDir }) => {
      const fetch = mockFetch({ "POST /prompt": new Error("ECONNREFUSED") });
      await expect(genAudio("creature-0001", "collect", recipe(),
        { fetch, host: "http://127.0.0.1:8188", templatesDir, gamesDir, pollIntervalMs: 0 }))
        .rejects.toThrow(/127\.0\.0\.1:8188|unreachable/);
      expect(existsSync(pjoin(gamesDir, "creature-0001", "audio", "collect.wav"))).toBe(false);
    });
  });

  test("throws (writing no file) when the recipe omits format", async () => {
    await withDirs(async ({ templatesDir, gamesDir }) => {
      const fetch = mockFetch({});
      const r = recipe();
      delete r.format;
      await expect(genAudio("creature-0001", "collect", r, { fetch, templatesDir, gamesDir, pollIntervalMs: 0 }))
        .rejects.toThrow(/format/);
      expect(existsSync(pjoin(gamesDir, "creature-0001", "audio", "collect.undefined"))).toBe(false);
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

// Build a mono 16-bit WAV: `pre` ms of near-silence, `tone` ms of a sine at
// amplitude `amp`, `post` ms of near-silence. Returns a Buffer via encodeWav so
// these tests don't depend on a real ComfyUI clip.
function makeWav({ rate = 44100, pre = 100, tone = 80, post = 120, amp = 0.5, freq = 440 } = {}) {
  const ms = (m) => Math.floor((rate * m) / 1000);
  const n = ms(pre) + ms(tone) + ms(post);
  const ch = new Float32Array(n);
  const start = ms(pre), end = ms(pre) + ms(tone);
  for (let i = 0; i < n; i++) {
    if (i >= start && i < end) ch[i] = amp * Math.sin((2 * Math.PI * freq * (i - start)) / rate);
    else ch[i] = 0.0002 * Math.sin(i); // sub-threshold "silence"
  }
  return encodeWav(1, rate, [ch]);
}

describe("encodeWav / decodeWav", () => {
  test("round-trips channels, rate, and samples within int16 quantization", () => {
    const rate = 22050;
    const a = new Float32Array([0, 0.5, -0.5, 0.999, -0.999, 0.25]);
    const buf = encodeWav(1, rate, [a]);
    const out = decodeWav(buf);
    expect(out.channels).toBe(1);
    expect(out.sampleRate).toBe(rate);
    expect(out.bitDepth).toBe(16);
    for (let i = 0; i < a.length; i++) expect(Math.abs(out.samples[0][i] - a[i])).toBeLessThan(1 / 32000);
  });

  test("throws on a non-RIFF buffer", () => {
    expect(() => decodeWav(Buffer.from("not a wav at all, just text......"))).toThrow(/RIFF|WAVE/);
  });
});

describe("envelopeSfxWav", () => {
  test("trims leading/trailing near-silence to roughly the event + pad", () => {
    const rate = 44100;
    const buf = makeWav({ rate, pre: 100, tone: 80, post: 120, amp: 0.5 });
    const out = decodeWav(envelopeSfxWav(buf));
    const inMs = (decodeWav(buf).samples[0].length / rate) * 1000;
    const outMs = (out.samples[0].length / rate) * 1000;
    expect(outMs).toBeLessThan(inMs);            // silence was trimmed
    expect(outMs).toBeGreaterThan(80);           // the 80 ms event survived
    expect(outMs).toBeLessThan(80 + 2 * 8 + 5);  // ~ event + 2*pad(8ms), small tolerance
  });

  test("loudness-normalizes a quiet clip up toward the RMS target", () => {
    const out = decodeWav(envelopeSfxWav(makeWav({ amp: 0.03, pre: 20, post: 20 })));
    const s = out.samples[0];
    let sumsq = 0; for (let i = 0; i < s.length; i++) sumsq += s[i] * s[i];
    const rms = Math.sqrt(sumsq / s.length);
    expect(rms).toBeGreaterThan(0.08); // lifted well above the 0.03 input toward 0.13
  });

  test("never exceeds the peak clamp", () => {
    const out = decodeWav(envelopeSfxWav(makeWav({ amp: 0.9, pre: 20, post: 20 })));
    let pk = 0; for (const v of out.samples[0]) pk = Math.max(pk, Math.abs(v));
    expect(pk).toBeLessThanOrEqual(0.97 + 1e-3);
  });

  test("applies fades — first and last samples are ~silent", () => {
    const out = decodeWav(envelopeSfxWav(makeWav({ amp: 0.5 })));
    const s = out.samples[0];
    expect(Math.abs(s[0])).toBeLessThan(0.05);
    expect(Math.abs(s[s.length - 1])).toBeLessThan(0.05);
  });

  test("does not mutate the input buffer", () => {
    const buf = makeWav({ amp: 0.5 });
    const before = Buffer.from(buf);
    envelopeSfxWav(buf);
    expect(buf.equals(before)).toBe(true);
  });
});
