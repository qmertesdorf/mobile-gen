import { test, expect, describe } from "vitest";
import { validate, newManifest, setStatus, STATUSES, merge } from "./manifest.mjs";

// A hand-built, fully-valid manifest used as the baseline across tests.
function validManifest() {
  return {
    id: "runner-0001",
    name: "Neon Dash",
    created_at: "2026-05-30T12:00:00Z",
    updated_at: "2026-05-30T12:00:00Z",
    status: "playable",
    concept: {
      genre: "endless runner",
      core_loop: "tap to jump, avoid obstacles",
      mechanics: ["jump", "score"],
      art_direction: "neon vector, dark background",
      target_platforms: ["android"],
      differentiation_notes: "single-tap control"
    },
    build: {
      engine: "godot",
      engine_version: "4.6.3.stable",
      language: "gdscript",
      project_path: "games/runner-0001/",
      addons: [],
      export_presets: ["android"]
    },
    assets: [{ type: "sprite", name: "player", source: "placeholder", origin: "primitive" }],
    validation: { opens_in_editor: true, runs: true, core_loop_functional: true, issues: [] },
    _reserved: { compliance: null, store: null, maintenance: null }
  };
}

describe("validate", () => {
  test("accepts a fully-formed manifest", () => {
    expect(validate(validManifest())).toEqual({ valid: true, errors: [] });
  });

  test("rejects an unknown status", () => {
    const m = validManifest();
    m.status = "shipped";
    const result = validate(m);
    expect(result.valid).toBe(false);
    expect(result.errors.join(" ")).toMatch(/status/);
  });

  test("rejects a missing required top-level key", () => {
    const m = validManifest();
    delete m._reserved;
    expect(validate(m).valid).toBe(false);
  });

  test("accepts a styled manifest carrying asset_pass and origin:svg assets", () => {
    const m = validManifest();
    m.status = "styled";
    m.assets = [{ type: "sprite", name: "player", source: "art/player.svg", origin: "svg" }];
    m.asset_pass = {
      method: "svg",
      visual_system: {
        palette: ["#0a0a14", "#00e5ff", "#ff3df0", "#ffe24a"],
        stroke: "2px round, additive glow",
        form: "sharp-cornered geometric, low detail",
        shading: "flat fill + outer glow halo",
        scale: "SVGs scaled to primitive footprints; 10% internal padding"
      },
      reskinned: ["player", "obstacle", "pickup"],
      left_primitive: ["background", "glow", "particles"],
      art_path: "games/runner-0002/art/",
      notes: "background kept procedural; art_direction is geometric, well within SVG scope"
    };
    expect(validate(m)).toEqual({ valid: true, errors: [] });
  });

  test("rejects an unknown key inside asset_pass", () => {
    const m = validManifest();
    m.status = "styled";
    m.asset_pass = { method: "svg", bogus: true };
    expect(validate(m).valid).toBe(false);
  });

  test("still accepts an existing playable manifest with no asset_pass (no regression)", () => {
    const m = validManifest(); // status: "playable", no asset_pass
    expect(validate(m)).toEqual({ valid: true, errors: [] });
  });

  test("accepts a styled manifest carrying a raster asset_pass (style, prompt_scaffold, recipes)", () => {
    const m = validManifest();
    m.status = "styled";
    m.assets = [{ type: "sprite", name: "hero", source: "art/hero.png", origin: "raster" }];
    m.asset_pass = {
      method: "raster",
      visual_system: {
        palette: ["#1a1226", "#e0b15a", "#6cc4d6", "#c8503a"],
        form: "stout painted creatures, soft edges",
        shading: "painterly, single warm key light",
        scale: "512px masters downscaled to footprint",
        prompt_scaffold: "painterly fantasy creature, soft brushwork, warm key light, plain background",
        style: {
          checkpoint: "dreamshaperXL.safetensors",
          loras: ["painterly-creatures-v2.safetensors"],
          style_prompt: "painterly, illustrated, soft brushwork"
        }
      },
      reskinned: ["hero", "enemy"],
      left_primitive: ["hpbar", "background"],
      art_path: "games/creature-0001/art/",
      notes: "art_direction is illustrated/representational — raster (M1.5) is the right method; hpbar left primitive (crisp vector is better for a UI bar)",
      recipes: [
        {
          name: "hero",
          checkpoint: "dreamshaperXL.safetensors",
          prompt: "painterly fantasy creature, soft brushwork, warm key light, plain background, a small round forest spirit",
          negative: "logo, watermark, text, trademarked character, celebrity, low quality",
          seed: 123456,
          sampler: "dpmpp_2m",
          steps: 30,
          cfg: 6.5,
          master_resolution: 512,
          layerdiffuse: true,
          lora: "painterly-creatures-v2.safetensors",
          import_settings: { mipmaps: true, filter: "linear", compression: "lossless" }
        }
      ]
    };
    expect(validate(m)).toEqual({ valid: true, errors: [] });
  });

  test("rejects an unknown key inside a recipe", () => {
    const m = validManifest();
    m.status = "styled";
    m.asset_pass = {
      method: "raster",
      recipes: [{ name: "hero", bogus: true }]
    };
    expect(validate(m).valid).toBe(false);
  });

  test("rejects an unknown key inside visual_system.style", () => {
    const m = validManifest();
    m.status = "styled";
    m.asset_pass = {
      method: "raster",
      visual_system: { style: { checkpoint: "x.safetensors", bogus: true } }
    };
    expect(validate(m).valid).toBe(false);
  });

  test("accepts a scored manifest carrying an audio_pass", () => {
    const m = validManifest();
    m.status = "scored";
    m.audio_pass = {
      method: "audio",
      audio_system: { model: "stable-audio-open-1.0", mood_prompt: "calm forest", style_descriptors: ["ambient", "soft"] },
      recipes: [{
        name: "collect", kind: "sfx", prompt: "soft chime pickup", negative: "music, voice",
        seed: 7, duration_s: 0.8, sampler: "dpmpp_3m_sde_gpu", steps: 8, cfg: 6, format: "wav",
        loop: false, import_settings: { loop: false, loop_offset: 0 }
      }],
      events: [{ event: "collect", clip: "collect", node: "SfxCollect", signal: "seed_collected" }],
      notes: "music + 1 sfx"
    };
    expect(validate(m)).toEqual({ valid: true, errors: [] });
  });

  test("rejects an unknown key inside audio_pass", () => {
    const m = validManifest();
    m.status = "scored";
    m.audio_pass = { method: "audio", bogus: true };
    expect(validate(m).valid).toBe(false);
  });

  test("audio_pass is optional (no regression for pre-audio manifests)", () => {
    expect(validate(validManifest()).valid).toBe(true);
  });
});

describe("newManifest", () => {
  test("produces a schema-valid skeleton with status=concept", () => {
    const m = newManifest({ id: "runner-0001", name: "Neon Dash" }, "2026-05-30T12:00:00Z");
    expect(m.id).toBe("runner-0001");
    expect(m.name).toBe("Neon Dash");
    expect(m.status).toBe("concept");
    expect(m.created_at).toBe("2026-05-30T12:00:00Z");
    expect(m.updated_at).toBe("2026-05-30T12:00:00Z");
    expect(m._reserved).toEqual({ compliance: null, store: null, maintenance: null });
    expect(validate(m).valid).toBe(true);
  });

  test("throws when id or name is missing", () => {
    expect(() => newManifest({ id: "x" })).toThrow();
    expect(() => newManifest({ name: "y" })).toThrow();
  });
});

describe("setStatus", () => {
  const base = () => newManifest({ id: "a", name: "A" }, "2026-05-30T12:00:00Z");

  test("exposes the seven statuses through scored", () => {
    expect(STATUSES).toEqual(["concept", "generated", "validated", "playable", "styled", "scored", "failed"]);
  });

  test("advances along the legal path and stamps updated_at", () => {
    const m = setStatus(base(), "generated", "2026-05-30T13:00:00Z");
    expect(m.status).toBe("generated");
    expect(m.updated_at).toBe("2026-05-30T13:00:00Z");
    expect(m.created_at).toBe("2026-05-30T12:00:00Z"); // unchanged
  });

  test("allows any non-terminal status to fail", () => {
    expect(setStatus(base(), "failed").status).toBe("failed");
  });

  test("rejects skipping a step", () => {
    expect(() => setStatus(base(), "playable")).toThrow(/concept -> playable/);
  });

  test("rejects an unknown status", () => {
    expect(() => setStatus(base(), "shipped")).toThrow(/unknown status/);
  });

  test("rejects leaving a terminal status", () => {
    const failed = setStatus(base(), "failed");
    expect(() => setStatus(failed, "generated")).toThrow();
  });

  test("treats re-setting the same status as a no-op", () => {
    expect(setStatus(base(), "concept").status).toBe("concept");
  });

  test("advances playable -> styled", () => {
    const playable = { ...base(), status: "playable" };
    const styled = setStatus(playable, "styled", "2026-05-30T14:00:00Z");
    expect(styled.status).toBe("styled");
    expect(styled.updated_at).toBe("2026-05-30T14:00:00Z");
  });

  test("allows playable -> failed", () => {
    const playable = { ...base(), status: "playable" };
    expect(setStatus(playable, "failed").status).toBe("failed");
  });

  test("rejects back-transition from styled to playable", () => {
    const styled = { ...base(), status: "styled" };
    expect(() => setStatus(styled, "playable")).toThrow(/illegal transition/);
  });

  test("playable can advance to scored", () => {
    const m = { ...base(), status: "playable" };
    expect(setStatus(m, "scored").status).toBe("scored");
  });
  test("styled can advance to scored (visual pass first)", () => {
    const m = { ...base(), status: "styled" };
    expect(setStatus(m, "scored").status).toBe("scored");
  });
  test("scored can advance to styled (audio pass first)", () => {
    const m = { ...base(), status: "scored" };
    expect(setStatus(m, "styled").status).toBe("styled");
  });
  test("scored can fail", () => {
    const m = { ...base(), status: "scored" };
    expect(setStatus(m, "failed").status).toBe("failed");
  });
});

describe("merge", () => {
  const base = () => newManifest({ id: "a", name: "A" }, "2026-05-30T12:00:00Z");

  test("deep-merges a nested block and stamps updated_at", () => {
    const m = merge(base(), { concept: { genre: "endless runner", mechanics: ["jump"] } }, "2026-05-30T13:00:00Z");
    expect(m.concept.genre).toBe("endless runner");
    expect(m.concept.mechanics).toEqual(["jump"]);
    expect(m.updated_at).toBe("2026-05-30T13:00:00Z");
    expect(m.status).toBe("concept"); // untouched
  });

  test("replaces arrays wholesale rather than concatenating", () => {
    const once = merge(base(), { concept: { mechanics: ["jump"] } });
    const twice = merge(once, { concept: { mechanics: ["jump", "double-jump"] } });
    expect(twice.concept.mechanics).toEqual(["jump", "double-jump"]);
  });

  test("does not mutate the input manifest", () => {
    const original = base();
    merge(original, { concept: { genre: "match-3" } });
    expect(original.concept.genre).toBeUndefined();
  });
});

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync as rf, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join as pjoin } from "node:path";
import { fileURLToPath as f2p } from "node:url";

const CLI = f2p(new URL("./manifest.mjs", import.meta.url));

function runCli(args, dir) {
  return execFileSync(process.execPath, [CLI, ...args], {
    env: { ...process.env, GAMEFORGE_MANIFEST_DIR: dir },
    encoding: "utf8"
  });
}

describe("CLI", () => {
  test("create → merge → set-status → validate round-trips on disk", () => {
    const dir = mkdtempSync(pjoin(tmpdir(), "gf-"));
    try {
      runCli(["create", "runner-0001", "Neon Dash"], dir);
      runCli(["merge", "runner-0001", JSON.stringify({ concept: { genre: "endless runner" } })], dir);
      runCli(["set-status", "runner-0001", "generated"], dir);
      const out = runCli(["validate", "runner-0001"], dir);
      expect(out).toMatch(/OK/);

      const m = JSON.parse(rf(pjoin(dir, "runner-0001.json"), "utf8"));
      expect(m.status).toBe("generated");
      expect(m.concept.genre).toBe("endless runner");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("validate exits non-zero on a hand-corrupted manifest", () => {
    const dir = mkdtempSync(pjoin(tmpdir(), "gf-"));
    try {
      runCli(["create", "bad-0001", "Bad"], dir);
      const p = pjoin(dir, "bad-0001.json");
      const m = JSON.parse(rf(p, "utf8"));
      m.status = "shipped";
      writeFileSync(p, JSON.stringify(m));
      expect(() => runCli(["validate", "bad-0001"], dir)).toThrow();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
