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

  test("exposes the six statuses through styled", () => {
    expect(STATUSES).toEqual(["concept", "generated", "validated", "playable", "styled", "failed"]);
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

  test("rejects leaving styled (terminal)", () => {
    const styled = { ...base(), status: "styled" };
    expect(() => setStatus(styled, "playable")).toThrow(/illegal transition/);
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
