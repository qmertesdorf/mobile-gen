# A/B-round-3 audio+art quality fix — Phase 1 codify — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Codify the A/B-round-3 calibration winners into the skill loop so the *next* game benefits — a deterministic, vitest-tested SFX envelope seam in `comfy.mjs`, an `%scheduler%` token, distinct width/height for backgrounds, an opt-in refine-pass template, and the corrected `audio/SKILL.md` + `asset/SKILL.md` guidance.

**Architecture:** Mirror the existing `comfy.mjs`/`package.mjs` pure-seam pattern — pure functions (Buffer→Buffer for audio, recipe→graph for images) that are vitest-tested with no GPU/network, plus prose edits to the two SKILL.md files. Audio changes are GPU-validated (Phase-0 probe); art changes (refine pass, background generation, sizing defaults) are codified from reasoning per owner decision 2026-06-02 and **must be GPU-validated at Phase 2 regeneration** — every such art change is flagged UNPROVEN in the SKILL.md so the risk stays legible.

**Tech Stack:** Node ESM (`tools/*.mjs`), vitest (`npm test` → `vitest run`), ComfyUI graph JSON templates, Claude-authored SKILL.md prose.

**Evidence base:** `docs/superpowers/2026-06-02-audio-art-probe-results.md` (locked settings) and `docs/superpowers/specs/2026-06-02-audio-art-quality-fix-design.md` (design). The validated envelope prototype is the throwaway `tools/_cozy_process.mjs` (trim-to-event → loudness-normalize to RMS 0.13 + peak clamp 0.97 → fade-in 6 ms / fade-out 40 ms).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `tools/comfy.mjs` | raster+audio HTTP plumbing + pure seams | add `decodeWav`/`encodeWav`/`envelopeSfxWav`; apply envelope in `genAudio` for `kind:"sfx"`; add `%scheduler%` token; distinct `%width%`/`%height%`; refine branch in `templateName` |
| `tools/comfy.test.mjs` | vitest for comfy.mjs | new envelope tests; updated genAudio sfx tests; scheduler/width/height/refine `injectRecipe`+`templateName` tests |
| `tools/comfy-templates/sdxl.json` | opaque image graph (used by background gen) | `scheduler` → `%scheduler%` |
| `tools/comfy-templates/sdxl-layerdiffuse.json` | RGBA sprite graph | `scheduler` → `%scheduler%` |
| `tools/comfy-templates/sdxl-layerdiffuse-lora.json` | RGBA sprite graph w/ LoRA | `scheduler` → `%scheduler%` |
| `tools/comfy-templates/sdxl-layerdiffuse-refine.json` | NEW — RGBA sprite graph w/ hi-res refine pass | create |
| `.claude/skills/audio/SKILL.md` | audio re-skin guidance | SFX steps 8→50–100; real applied envelope; cozy timbre=kalimba; BGM force-melody+anti-drone+register; locked per-game reference |
| `.claude/skills/asset/SKILL.md` | art re-skin guidance | background-generation capability; hero sizing/composition; sprite-gen tuning (scheduler+refine, UNPROVEN); raster-default tilt |

Tasks 1–5 are code (TDD). Tasks 6–7 are prose (verified by keeping the whole suite green). Task 8 is the final verification + record.

---

### Task 1: WAV envelope pure helpers (`decodeWav`, `encodeWav`, `envelopeSfxWav`)

**Files:**
- Modify: `tools/comfy.mjs` (add the seam near the top-level pure functions, after `injectRecipe`)
- Test: `tools/comfy.test.mjs` (new `describe("envelopeSfxWav")` block at end of file)

- [ ] **Step 1: Write the failing tests**

Append to `tools/comfy.test.mjs`:

```js
import { decodeWav, encodeWav, envelopeSfxWav } from "./comfy.mjs";

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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test -- comfy`
Expected: FAIL — `decodeWav`/`encodeWav`/`envelopeSfxWav` are not exported (import error / not a function).

- [ ] **Step 3: Implement the seam in `tools/comfy.mjs`**

Insert immediately after the `injectRecipe` function (after its closing `}` near line 50), before `const sleep = ...`:

```js
// ---- WAV post-process seam (SFX envelope) -------------------------------
// Stable Audio Open (via the soundfile-WAV patch on the pinned torch 2.11 stack)
// emits 16-bit PCM WAV. These helpers decode that to per-channel float, apply the
// SFX envelope the A/B-round-3 probe locked in, and re-encode. Pure: Buffer in,
// Buffer out — no disk, no network, no input mutation (slice() copies). The
// envelope (trim-to-event → loudness-normalize → fades) is what turns a raw SAO
// clip from "explosive / too quiet" into a clean, perceptibly-loud one-shot.
// Evidence + the validated prototype: docs/superpowers/2026-06-02-audio-art-probe-results.md.

export function decodeWav(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 44) {
    throw new Error("comfy: decodeWav requires a WAV buffer of at least 44 bytes");
  }
  if (buf.toString("latin1", 0, 4) !== "RIFF" || buf.toString("latin1", 8, 12) !== "WAVE") {
    throw new Error("comfy: decodeWav: not a RIFF/WAVE file");
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
  const frames = Math.floor(dataLen / 2 / channels);
  const samples = [];
  for (let c = 0; c < channels; c++) samples.push(new Float32Array(frames));
  for (let i = 0; i < frames; i++) {
    for (let c = 0; c < channels; c++) {
      samples[c][i] = buf.readInt16LE(dataOff + (i * channels + c) * 2) / 32768;
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm test -- comfy`
Expected: PASS — the new `encodeWav/decodeWav` and `envelopeSfxWav` describes are green, and all pre-existing comfy tests still pass.

- [ ] **Step 5: Commit**

```bash
git add tools/comfy.mjs tools/comfy.test.mjs
git commit -m "feat(comfy): pure WAV SFX envelope seam (trim/loudness/fades)"
```

---

### Task 2: Apply the envelope in `genAudio` for `kind:"sfx"`

**Files:**
- Modify: `tools/comfy.mjs:172-194` (`genAudio` — apply envelope to downloaded bytes for SFX only)
- Test: `tools/comfy.test.mjs` (update the `genAudio` happy-path sfx test; add a music-untouched test)

- [ ] **Step 1: Update the failing tests**

In `tools/comfy.test.mjs`, the existing `describe("genAudio")` happy-path test feeds the literal `"WAVDATA"`, which is not a parseable WAV — once the envelope runs on SFX it will throw. Replace that first test (`test("happy path: submits, polls, downloads, writes the audio file ...")`) with this version, which feeds a real WAV built from `encodeWav` and asserts the written file is a valid, enveloped WAV:

```js
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
```

Add `encodeWav` and `decodeWav` to the `import { genAudio } from "./comfy.mjs";` area if not already imported in that scope — they are exported and may already be imported at the top of the envelope block; a second `import { decodeWav, encodeWav } from "./comfy.mjs";` line is harmless in ESM but prefer reusing the existing one.

Then, in the `genAudio` `describe`, after the `.ogg` test, add a music-untouched assertion:

```js
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test -- comfy`
Expected: FAIL — the sfx happy-path test fails because `genAudio` currently writes raw bytes (no envelope; `written.samples[0].length` equals `n`, not less).

- [ ] **Step 3: Apply the envelope in `genAudio`**

In `tools/comfy.mjs`, change the `runGraph` result handling inside `genAudio` (currently line 187):

```js
  const { bytes, prompt_id } = await runGraph(workflow, { fetch, host, pollIntervalMs, maxPolls, pick: firstAudio, label: "audio" });
```

to:

```js
  const { bytes: rawBytes, prompt_id } = await runGraph(workflow, { fetch, host, pollIntervalMs, maxPolls, pick: firstAudio, label: "audio" });
  // SFX get the deterministic envelope (trim/loudness/fades); music is written as-is.
  const bytes = recipe.kind === "sfx" ? envelopeSfxWav(rawBytes) : rawBytes;
```

(`bytes` is then used unchanged by the existing `writeFileSync(outPath, bytes)`.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm test -- comfy`
Expected: PASS — sfx clip is enveloped (trimmed, valid WAV); music passes through unchanged.

- [ ] **Step 5: Commit**

```bash
git add tools/comfy.mjs tools/comfy.test.mjs
git commit -m "feat(comfy): apply SFX envelope in genAudio for kind:sfx; music untouched"
```

---

### Task 3: `%scheduler%` token + tokenize the image templates

**Files:**
- Modify: `tools/comfy.mjs:16-28` (add `%scheduler%` to `TOKENS`)
- Modify: `tools/comfy-templates/sdxl.json:26`, `sdxl-layerdiffuse.json:30`, `sdxl-layerdiffuse-lora.json:34` (`"scheduler": "normal"` → `"scheduler": "%scheduler%"`)
- Test: `tools/comfy.test.mjs` (`injectRecipe` describe)

- [ ] **Step 1: Write the failing tests**

In the `describe("injectRecipe")` block of `tools/comfy.test.mjs`, add:

```js
  test("fills %scheduler% from recipe.scheduler, defaulting to normal when omitted", () => {
    const tpl = { "3": { class_type: "KSampler", inputs: { scheduler: "%scheduler%" } } };
    expect(injectRecipe(tpl, { ...fullRecipe(), scheduler: "karras" })["3"].inputs.scheduler).toBe("karras");
    expect(injectRecipe(tpl, fullRecipe())["3"].inputs.scheduler).toBe("normal"); // default, like %negative%
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- comfy`
Expected: FAIL — `%scheduler%` is not a known token, so `injectRecipe` leaves the literal string `"%scheduler%"` (assertion `toBe("normal")`/`toBe("karras")` fails).

- [ ] **Step 3: Add the token**

In `tools/comfy.mjs`, add to the `TOKENS` object (after the `%duration%` line, keeping the same comment style):

```js
  "%scheduler%": (r) => r.scheduler ?? "normal" // default "normal" (the LayerDiffuse-safe scheduler); recipes opt into "karras"
```

(Add a trailing comma to the preceding `%duration%` entry as needed so the object stays valid.)

- [ ] **Step 4: Tokenize the three image templates**

In each of `tools/comfy-templates/sdxl.json`, `sdxl-layerdiffuse.json`, and `sdxl-layerdiffuse-lora.json`, change the KSampler line:

```json
      "scheduler": "normal",
```
to:
```json
      "scheduler": "%scheduler%",
```

(`stable-audio.json` keeps its hardcoded `"exponential"` — audio scheduler is not tuned this round.)

- [ ] **Step 5: Run to verify it passes**

Run: `npm test -- comfy`
Expected: PASS — scheduler fills from recipe or defaults to `normal`. Existing tests (no `scheduler` field) still pass because the default preserves prior behavior.

- [ ] **Step 6: Commit**

```bash
git add tools/comfy.mjs tools/comfy.test.mjs tools/comfy-templates/sdxl.json tools/comfy-templates/sdxl-layerdiffuse.json tools/comfy-templates/sdxl-layerdiffuse-lora.json
git commit -m "feat(comfy): %scheduler% token (default normal, opt-in karras)"
```

---

### Task 4: Distinct `%width%` / `%height%` for non-square (background) generation

**Files:**
- Modify: `tools/comfy.mjs:24-25` (`%width%`/`%height%` resolvers)
- Test: `tools/comfy.test.mjs` (`injectRecipe` describe)

**Why:** A background is a full-frame, opaque, *non-square* image. Today both `%width%` and `%height%` resolve to `master_resolution` (square only). Make them prefer explicit `width`/`height`, falling back to `master_resolution` so every existing square recipe is unchanged.

- [ ] **Step 1: Write the failing tests**

In `describe("injectRecipe")`:

```js
  test("%width%/%height% prefer explicit width/height, else fall back to master_resolution", () => {
    const tpl = { "5": { class_type: "EmptyLatentImage", inputs: { width: "%width%", height: "%height%" } } };
    const wide = injectRecipe(tpl, { ...fullRecipe(), width: 1280, height: 768 })["5"].inputs;
    expect(wide.width).toBe(1280);
    expect(wide.height).toBe(768);
    const square = injectRecipe(tpl, fullRecipe())["5"].inputs; // only master_resolution:512
    expect(square.width).toBe(512);
    expect(square.height).toBe(512);
  });

  test("%width% throws when neither width nor master_resolution is set", () => {
    const tpl = { "5": { class_type: "EmptyLatentImage", inputs: { width: "%width%" } } };
    const r = fullRecipe(); delete r.master_resolution;
    expect(() => injectRecipe(tpl, r)).toThrow(/%width%|width/);
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- comfy`
Expected: FAIL — current resolvers ignore `width`/`height`, so `wide.width` is `512` not `1280`.

- [ ] **Step 3: Update the resolvers**

In `tools/comfy.mjs` `TOKENS`, change:

```js
  "%width%": (r) => r.master_resolution,
  "%height%": (r) => r.master_resolution,
```
to:
```js
  "%width%": (r) => r.width ?? r.master_resolution,   // non-square (background) recipes set width/height; square sprites use master_resolution
  "%height%": (r) => r.height ?? r.master_resolution,
```

Update the comment above `TOKENS` (line 13-15) note that `master_resolution` fills width AND height *when explicit width/height are absent*.

- [ ] **Step 4: Run to verify it passes**

Run: `npm test -- comfy`
Expected: PASS — explicit width/height honored; square recipes unchanged; missing-both still throws loudly.

- [ ] **Step 5: Commit**

```bash
git add tools/comfy.mjs tools/comfy.test.mjs
git commit -m "feat(comfy): distinct %width%/%height% for non-square background gen"
```

---

### Task 5: Refine-pass template + `templateName` branch (opt-in, UNPROVEN)

**Files:**
- Create: `tools/comfy-templates/sdxl-layerdiffuse-refine.json`
- Modify: `tools/comfy.mjs:73-77` (`templateName` — add refine branch)
- Test: `tools/comfy.test.mjs` (`describe("templateName")`)

**Why / caveat:** Owner chose to codify a hi-res refine pass from reasoning (2026-06-02). It is a SEPARATE template selected only when `recipe.refine === true`, so the default sprite path is byte-for-byte unchanged. **This graph is UNPROVEN on the GPU** — LayerDiffuse's alpha-join may misbehave on an upscaled latent (the asset skill warns karras/Attention-Injection "produced mud"). It must be GPU-validated at Phase 2 before being trusted; the `asset/SKILL.md` edit in Task 7 says so.

- [ ] **Step 1: Write the failing test**

In `describe("templateName")` of `tools/comfy.test.mjs`:

```js
  test("layerdiffuse + refine (no lora) → sdxl-layerdiffuse-refine", () => {
    expect(templateName({ layerdiffuse: true, refine: true })).toBe("sdxl-layerdiffuse-refine");
  });
  test("layerdiffuse + refine + lora still → lora template (refine+lora unsupported this round)", () => {
    expect(templateName({ layerdiffuse: true, refine: true, lora: "x.safetensors" })).toBe("sdxl-layerdiffuse-lora");
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- comfy`
Expected: FAIL — `templateName` returns `sdxl-layerdiffuse`, not `sdxl-layerdiffuse-refine`.

- [ ] **Step 3: Add the `templateName` branch**

In `tools/comfy.mjs`, change `templateName`:

```js
function templateName(recipe) {
  if (recipe.kind === "sfx" || recipe.kind === "music") return "stable-audio";
  if (!recipe.layerdiffuse) return "sdxl";
  if (recipe.refine && !recipe.lora) return "sdxl-layerdiffuse-refine"; // hi-res second pass; refine+lora not supported this round
  return recipe.lora ? "sdxl-layerdiffuse-lora" : "sdxl-layerdiffuse";
}
```

- [ ] **Step 4: Create the refine template**

Create `tools/comfy-templates/sdxl-layerdiffuse-refine.json`. It mirrors `sdxl-layerdiffuse.json` but inserts a `LatentUpscaleBy` + a second low-denoise `KSampler` between the base sampler and the decode, so both the VAE decode and the LayerDiffuse RGBA decode read the *refined* latent:

```json
{
  "ckpt": {
    "class_type": "CheckpointLoaderSimple",
    "inputs": { "ckpt_name": "%checkpoint%" }
  },
  "ld_apply": {
    "class_type": "LayeredDiffusionApply",
    "inputs": { "model": ["ckpt", 0], "config": "SDXL, Conv Injection", "weight": 1.0 }
  },
  "pos": {
    "class_type": "CLIPTextEncode",
    "inputs": { "text": "%prompt%", "clip": ["ckpt", 1] }
  },
  "neg": {
    "class_type": "CLIPTextEncode",
    "inputs": { "text": "%negative%", "clip": ["ckpt", 1] }
  },
  "latent": {
    "class_type": "EmptyLatentImage",
    "inputs": { "width": "%width%", "height": "%height%", "batch_size": 1 }
  },
  "ksampler": {
    "class_type": "KSampler",
    "inputs": {
      "model": ["ld_apply", 0],
      "seed": "%seed%",
      "steps": "%steps%",
      "cfg": "%cfg%",
      "sampler_name": "%sampler%",
      "scheduler": "%scheduler%",
      "positive": ["pos", 0],
      "negative": ["neg", 0],
      "latent_image": ["latent", 0],
      "denoise": 1.0
    }
  },
  "upscale": {
    "class_type": "LatentUpscaleBy",
    "inputs": { "samples": ["ksampler", 0], "upscale_method": "bislerp", "scale_by": 1.5 }
  },
  "ksampler_refine": {
    "class_type": "KSampler",
    "inputs": {
      "model": ["ld_apply", 0],
      "seed": "%seed%",
      "steps": "%steps%",
      "cfg": "%cfg%",
      "sampler_name": "%sampler%",
      "scheduler": "%scheduler%",
      "positive": ["pos", 0],
      "negative": ["neg", 0],
      "latent_image": ["upscale", 0],
      "denoise": 0.45
    }
  },
  "vaedecode": {
    "class_type": "VAEDecode",
    "inputs": { "samples": ["ksampler_refine", 0], "vae": ["ckpt", 2] }
  },
  "ld_decode": {
    "class_type": "LayeredDiffusionDecodeRGBA",
    "inputs": { "samples": ["ksampler_refine", 0], "images": ["vaedecode", 0], "sd_version": "SDXL", "sub_batch_size": 16 }
  },
  "save": {
    "class_type": "SaveImage",
    "inputs": { "images": ["ld_decode", 0], "filename_prefix": "gameforge" }
  }
}
```

- [ ] **Step 5: Add a template-injection smoke test**

In `tools/comfy.test.mjs`, add (top-level, near the other file-reading tests — it reads the real template off disk so it guards token coverage):

```js
import { readFileSync as _rf } from "node:fs";
import { fileURLToPath as _ffu } from "node:url";
import { dirname as _dn, join as _jn } from "node:path";

test("refine template injects with a refine recipe (no leftover %tokens%)", () => {
  const dir = _dn(_ffu(import.meta.url));
  const tpl = JSON.parse(_rf(_jn(dir, "comfy-templates", "sdxl-layerdiffuse-refine.json"), "utf8"));
  const recipe = { checkpoint: "j.safetensors", prompt: "a hero", negative: "logo", seed: 1, sampler: "euler", steps: 24, cfg: 7, master_resolution: 1024, scheduler: "karras", layerdiffuse: true, refine: true };
  const out = JSON.stringify(injectRecipe(tpl, recipe));
  expect(out).not.toMatch(/%[a-z_]+%/); // every token resolved
  expect(JSON.parse(out).ksampler_refine.inputs.scheduler).toBe("karras");
});
```

- [ ] **Step 6: Run to verify all pass**

Run: `npm test -- comfy`
Expected: PASS — refine routing + template injection green.

- [ ] **Step 7: Commit**

```bash
git add tools/comfy.mjs tools/comfy.test.mjs tools/comfy-templates/sdxl-layerdiffuse-refine.json
git commit -m "feat(comfy): opt-in sdxl-layerdiffuse-refine hi-res pass (UNPROVEN, Phase-2 validate)"
```

---

### Task 6: `audio/SKILL.md` — codify the locked audio winners

**Files:**
- Modify: `.claude/skills/audio/SKILL.md`

No new test logic; the guardrail is `npm test` staying green (`tools/skills.test.mjs` validates SKILL.md structure/frontmatter — these edits stay inside existing sections so structure is preserved).

- [ ] **Step 1: Fix the `sonic_character` cozy-timbre guidance**

In the `sonic_character` bullet (the line that begins "`sonic_character`: the **SFX sound-material/timbre vocabulary**..."), replace the cozy example clause:

old: `a cozy/organic theme → "soft organic wooden/leaf/cloth taps, gentle, no electronic transients";`
new: `a cozy/organic theme → name a **concrete warm instrument** — "kalimba / thumb-piano (warm wooden pluck), soft organic taps, no electronic transients" (round-3: generic "bell chime"/music-box/celesta read as "irritating tings" — a named warm instrument is the cozy winner);`

- [ ] **Step 2: Rewrite the SFX recipe bullet (steps + real envelope)**

Replace the entire `- **SFX**: ...` bullet in section 3 (currently the line citing `steps` ~8) with:

```markdown
- **SFX**: `kind:"sfx"`, `format:"wav"`, `duration_s` **1.0–2.0** (`EmptyLatentAudio` enforces a 1.0 s minimum — do not go below), `loop:false`, **`steps` 50–100** (cozy ≈55, chiptune ≈100), `cfg` ~5–6. **steps≈8 is the round-3 explosive-SFX root cause** — under-denoised broadband noise (ZCR up to 8.9k/s) reads as a gunshot; 50–100 yields a clean tone. Each SFX prompt = `mood_prompt` + **`sonic_character`** + the clip-specific event description; name the warm instrument (kalimba) for cozy themes, clean square/triangle chip for arcade. The **envelope is now a real, deterministic post-process applied automatically** by `comfy.mjs` `genAudio` to every `kind:"sfx"` clip (`envelopeSfxWav`: trim-to-event → loudness-normalize to RMS ~0.13 with a 0.97 peak clamp → fade-in 6 ms / fade-out 40 ms) — you do **not** hand-apply it, but you must still generate at 50–100 steps so the *content* is clean before the envelope shapes it. The negative prompt always excludes "music, melody, voice, speech", **plus a theme-aware exclusion**: a cozy/organic theme adds "explosion, harsh, distortion, aggressive, electronic, gunshot"; an arcade theme keeps chip transients but still excludes "explosion, noise burst". (cfg too high can clip the transient.)
```

- [ ] **Step 3: Rewrite the Music recipe bullet (force-melody + anti-drone + register)**

Replace the `- **Music**: ...` bullet with:

```markdown
- **Music**: `kind:"music"`, `format:"wav"`, `duration_s` 20–40, `steps` ~50, `loop:true`, `import_settings:{loop:true, loop_offset:0}`. **Force a plucked/repeating MELODY, never an ambient pad** — round-3 root cause: ambient/pad/sustained prompts collapse to a DRONE ("single-toned, annoying"). Use `cfg` **8** and add aggressive anti-drone negatives: `"drone, pad, sustained, monotone, single note, held note, atmosphere, texture"`. **Register matters**: a cozy theme wants a **low, warm** bed — add `"high pitched, shrill, tinny, bright"` to the negatives and name a warm instrument (fingerpicked nylon-guitar lullaby). A naturally-melodic style (chiptune) needs only a "mellow" framing at `cfg` ~6. Target loop-friendly content (steady repeating melody, no hard intro/outro) — seamless looping is imperfect for generative output (known limitation). Note: WAV music is uncompressed (~5 MB / 30 s stereo); acceptable for a milestone, OGG is a future size optimization.
```

- [ ] **Step 4: Append a locked per-game reference block**

At the end of section 3 (after the IP-safety bullet), add:

```markdown

**Locked reference settings (A/B-round-3 probe, owner-confirmed by ear — `docs/superpowers/2026-06-02-audio-art-probe-results.md`):**
- creature (cozy) SFX: kalimba/mbira warm-wooden-pluck; steps 55, cfg 6, dur ~1.2 s + auto envelope.
- creature BGM: fingerpicked nylon-guitar lullaby, low/warm register, simple repeating melody; steps 50, cfg 8; anti-drone + anti-high-pitch negatives.
- crosser (arcade) SFX: clean square-wave chiptune; steps 100 + auto envelope.
- crosser BGM: mellow chiptune melody, soft square/triangle; steps 50, cfg 6.
```

- [ ] **Step 5: Verify the suite stays green**

Run: `npm test`
Expected: PASS (same count as before; SKILL.md structure tests unaffected).

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/audio/SKILL.md
git commit -m "docs(audio-skill): codify round-3 audio winners (steps 50-100, real envelope, kalimba, anti-drone BGM)"
```

---

### Task 7: `asset/SKILL.md` — background capability, sizing, sprite-gen tuning, raster-default

**Files:**
- Modify: `.claude/skills/asset/SKILL.md`

Guardrail: `npm test` stays green.

- [ ] **Step 1: Add the background-generation capability + sizing under the raster method**

Insert a new subsection immediately before `### Mixed-method honesty (inverted boundary)`:

```markdown
### Backgrounds & composition (round-3 — the real art-quality lever)

Round-3 playtests proved the sprites were already fine; "terrible" came from **flat primitive backgrounds + heroes too small**, not sprite quality. So this method now **generates environment art and sizes the hero deliberately** — this is where art quality actually lives.

> **UNPROVEN — validate at Phase 2.** Background generation and the refine pass below were codified from reasoning (owner decision 2026-06-02), NOT from a GPU probe. Generate, view, and owner-confirm them at regeneration before trusting these defaults; if a background comes back weak, that is a finding about *this guidance*, fixable here.

- **Background = full-frame OPAQUE image (no LayerDiffuse).** Use the plain `sdxl` template: recipe with `layerdiffuse:false`, **no** alpha, and explicit non-square `width`/`height` matching the game's aspect (e.g. `1280×768` landscape, `768×1280` portrait — `comfy.mjs` now honors distinct `width`/`height`). The prompt expresses `concept.theme.setting` as a *scene/environment* ("a cozy autumn-woodland glade, soft depth, storybook") — the same world the sprites inhabit. Draw it as the **bottom layer** (root `_draw()` background, or a full-rect `Sprite2D` at `z_index` below all actors) replacing the flat primitive band/void. Record it as a `reskinned` background entity with `origin:"raster"`.
- **This supersedes the old "background left primitive is an M1.7-deferred gap" default** (see the immediate-mode §c note) — a themed background is now **in scope and expected** for a representational title. Leaving it primitive is now the exception you must justify, not the default.
- **Size the hero for the frame.** A detailed sprite floating tiny on a large field reads cheap. Place the hero so it occupies a **prominent share of its play area** and is clearly larger than / distinct from hazards (round-3: the crosser cyan hero was tiny next to red hazards). Sizing is a *runtime scale at wire time* (the `Sprite2D` scale / `draw_texture_rect` dest size), not a generation parameter — set it so the hero reads as the subject. Record the intent in `asset_pass.notes`.
```

- [ ] **Step 2: Add sprite-gen tuning (scheduler + refine) to the raster "Proven defaults" bullet**

In the `### Per-entity flow` numbered list, append to the end of the **"Proven defaults (feasibility gate)"** sub-bullet (the one ending "...always downscale-from-master)."):

```markdown
   - **Sprite-gen tuning levers (round-3, opt-in, UNPROVEN — validate at Phase 2).** Owner chose to expose these; the round-3 probe found sprite tuning *low-ROI* vs. backgrounds, so reach for backgrounds/sizing first. Two levers exist: (1) **scheduler** — recipes may set `"scheduler":"karras"` (default `"normal"`); note the prior feasibility finding that `karras`+`Attention Injection` "produced mud", so confirm by eye before adopting. (2) **refine pass** — set `"refine":true` to route to the `sdxl-layerdiffuse-refine` template (a `LatentUpscaleBy` 1.5× + a denoise-0.45 second pass). The LayerDiffuse alpha-join on an upscaled latent is unverified — generate and inspect the RGBA edge before trusting it. `refine` + `lora` together is not supported this round.
```

- [ ] **Step 3: Re-tilt the method choice to raster-default**

In the `## Choosing the method (branch on \`concept.art_direction\`)` section, after the two method bullets (geometric→svg, representational→raster), append a principle line:

```markdown

**Raster is the default for art; do not retreat to SVG to dodge a quality problem** (owner directive 2026-06-02). SVG is reserved for a genuinely good reason — a pure UI/HUD/geometric element where vector resolution-independence is a real win. The remedy for "terrible" raster is to **lift raster quality** (backgrounds, sizing, the tuning levers above), not to fall back to vectors. State the justification when you do choose `svg` for an entity.
```

- [ ] **Step 4: Update the immediate-mode §c background note to point at the new capability**

In swap-pattern note **c) What stays primitive.**, replace the sentence beginning "**A background left primitive is a cohesion gap, not a free pass:**" through its end with:

```markdown
**A background left primitive is a cohesion gap, not a free pass:** sprites floating on untextured primitive bands undercut the one-rendered-system goal. As of round-3 the raster method **generates a themed background** (see "Backgrounds & composition") — that is now the expected fix. If you nonetheless leave the background primitive, you **must** list it in `left_primitive` and justify it in `asset_pass.notes`; never silently omit it.
```

- [ ] **Step 5: Verify the suite stays green**

Run: `npm test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/asset/SKILL.md
git commit -m "docs(asset-skill): background-gen capability + hero sizing + sprite-gen levers + raster-default (art UNPROVEN, Phase-2 validate)"
```

---

### Task 8: Final verification + record

**Files:** none (verification + memory)

- [ ] **Step 1: Run the full suite**

Run: `npm test`
Expected: PASS — all tests green, count = prior 140 + the new comfy tests added in Tasks 1–5.

- [ ] **Step 2: Sanity-check no template tokens were missed**

Run: `node -e "const{injectRecipe}=require('./tools/comfy.mjs')" 2>$null; npm test -- comfy`
(Primary signal is the green refine-template smoke test from Task 5, which asserts no leftover `%token%`.)

- [ ] **Step 3: Update memory**

Mark Phase 1 codify DONE in `C:\Users\quint\.claude\projects\C--Users-quint-git-mobile-gen\memory\ab-round3-audio-art-fix.md` (audio fully codified+validated; art codified-from-reasoning and **pending Phase-2 GPU validation**). Note Phase 2 (regenerate creature-0001 + crosser-0001 audio with locked settings, generate backgrounds + resize heroes, re-import, technical verify, owner re-playtest) and the throwaway-artifact cleanup remain.

---

## Phase 2 (out of scope for this plan — owner/GPU-gated, recorded for the resume)

Regenerate both proof games with the codified skills: free Ollama → boot ComfyUI (`run_comfyui.bat`) → `node tools/comfy.mjs --check` → restore godot shim. Regenerate audio (locked settings), generate backgrounds + resize heroes (**validate the refine pass / background quality here — this is where the UNPROVEN art changes get their GPU evidence**), `godot --headless --path games/<id>/ --import`, technical verify (selftest, headless run, NON-headless audio probe `playing==true`, screenshot), owner re-playtest → advance status. Then clean up the throwaway probe artifacts listed in the memory file.

## Self-Review

- **Spec coverage:** envelope seam ✅ (T1–2), `audio/SKILL.md` steps+envelope+BGM ✅ (T6), `asset/SKILL.md` raster-default+tuning ✅ (T7), `%scheduler%` token ✅ (T3), refine pass ✅ (T5) — plus the owner-expanded scope: background generation ✅ (T4 plumbing + T7 guidance) and hero sizing ✅ (T7). The spec listed background re-skin as out-of-scope; the 2026-06-02 owner decision pulled it in, recorded at plan top.
- **Placeholder scan:** every code step has complete code; SKILL.md steps give exact old→new prose.
- **Type/name consistency:** `decodeWav`/`encodeWav`/`envelopeSfxWav` used identically across T1, T2, T5 tests; `recipe.refine`/`recipe.scheduler`/`recipe.width`/`recipe.height` consistent across `comfy.mjs`, templates, and tests; template node id `ksampler_refine` referenced consistently in the refine JSON.
