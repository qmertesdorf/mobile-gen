import { test, expect, describe } from "vitest";
import { iconSizeTable, sizeBudget, pngSize, exportPresetCfg, parsePresetCfg, atlasLayout, splashSize, bootSplashCfg, verify, budgetReport, exportPresetsFile, buildArtifactPlan, androidToolchainPresent, buildArtifact, verifyBuildArtifact, packageNameFor } from "./package.mjs";
import { parseHexLead, resolveIconBg } from "./package.mjs";
import { iconCompositionRole } from "./package.mjs";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("iconSizeTable", () => {
  test("returns all 8 required Android icon outputs", () => {
    const t = iconSizeTable();
    expect(t).toHaveLength(8);
    for (const e of t) {
      expect(typeof e.name).toBe("string");
      expect(typeof e.px).toBe("number");
      expect(typeof e.kind).toBe("string");
    }
  });

  test("launcher densities mdpi→xxxhdpi at exact px", () => {
    const launchers = iconSizeTable().filter((e) => e.kind === "launcher");
    expect(launchers.map((e) => e.px)).toEqual([48, 72, 96, 144, 192]);
  });

  test("includes the Play hi-res 512 and adaptive fg/bg at 432", () => {
    const t = iconSizeTable();
    expect(t.find((e) => e.kind === "play").px).toBe(512);
    const adaptive = t.filter((e) => e.kind === "adaptive_fg" || e.kind === "adaptive_bg");
    expect(adaptive).toHaveLength(2);
    expect(adaptive.every((e) => e.px === 432)).toBe(true);
  });

  test("names are unique and it returns a fresh array each call", () => {
    const a = iconSizeTable();
    const b = iconSizeTable();
    const names = a.map((e) => e.name);
    expect(new Set(names).size).toBe(names.length);
    expect(a).not.toBe(b); // not a shared mutable singleton
  });
});

describe("sizeBudget", () => {
  test("sums bytes and reports a per-file breakdown", () => {
    const r = sizeBudget([{ path: "a.png", bytes: 100 }, { path: "b.png", bytes: 250 }], 1000);
    expect(r.total_bytes).toBe(350);
    expect(r.budget_bytes).toBe(1000);
    expect(r.pass).toBe(true);
    expect(r.per_file).toEqual([{ path: "a.png", bytes: 100 }, { path: "b.png", bytes: 250 }]);
  });

  test("passes at the exact boundary (total === budget)", () => {
    expect(sizeBudget([{ path: "a", bytes: 500 }], 500).pass).toBe(true);
  });

  test("fails when total exceeds budget", () => {
    expect(sizeBudget([{ path: "a", bytes: 501 }], 500).pass).toBe(false);
  });

  test("empty file list totals 0 and passes", () => {
    expect(sizeBudget([], 10)).toEqual({ total_bytes: 0, budget_bytes: 10, pass: true, per_file: [] });
  });

  test("throws on a non-array files arg", () => {
    expect(() => sizeBudget("nope", 10)).toThrow(/array/);
  });

  test("throws on a malformed entry", () => {
    expect(() => sizeBudget([{ path: "a" }], 10)).toThrow(/path.*bytes|bytes/);
  });
});

describe("pngSize", () => {
  // Build a minimal valid PNG header: 8-byte signature + IHDR length+type+w+h.
  function pngHeader(w, h) {
    const buf = Buffer.alloc(24);
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(buf, 0); // signature
    buf.writeUInt32BE(13, 8);            // IHDR chunk length
    buf.write("IHDR", 12, "latin1");     // chunk type
    buf.writeUInt32BE(w, 16);            // width
    buf.writeUInt32BE(h, 20);            // height
    return buf;
  }

  test("reads width and height from the IHDR chunk", () => {
    expect(pngSize(pngHeader(192, 192))).toEqual({ w: 192, h: 192 });
    expect(pngSize(pngHeader(1080, 1920))).toEqual({ w: 1080, h: 1920 });
  });

  test("throws on a non-PNG buffer", () => {
    expect(() => pngSize(Buffer.from("not a png at all....."))).toThrow(/signature|PNG/);
  });

  test("throws on a too-short buffer", () => {
    expect(() => pngSize(Buffer.alloc(10))).toThrow(/24|PNG/);
  });

  test("throws on a PNG with a non-IHDR first chunk", () => {
    const buf = pngHeader(48, 48);
    buf.write("tEXt", 12, "latin1"); // corrupt the chunk type
    expect(() => pngSize(buf)).toThrow(/IHDR|corrupt/);
  });
});

describe("exportPresetCfg + parsePresetCfg", () => {
  test("generates an Android preset that round-trips through the parser", () => {
    const cfg = exportPresetCfg({ id: "creature-0001", name: "Glade Spirit" });
    const parsed = parsePresetCfg(cfg);
    expect(parsed["preset.0"].platform).toBe("Android");
    expect(parsed["preset.0"].name).toBe("Glade Spirit");
    expect(parsed["preset.0"].runnable).toBe(true);
    expect(parsed["preset.0"].export_path).toBe("build/creature-0001-debug.apk");
    expect(parsed["preset.0.options"]["package/unique_name"]).toBe("com.gameforge.creature_0001");
    expect(parsed["preset.0.options"]["package/name"]).toBe("Glade Spirit");
  });

  test("honors an explicit packageName and exportPath", () => {
    const cfg = exportPresetCfg({ id: "x-0001", name: "X", packageName: "com.acme.x", exportPath: "out/x.apk" });
    const parsed = parsePresetCfg(cfg);
    expect(parsed["preset.0.options"]["package/unique_name"]).toBe("com.acme.x");
    expect(parsed["preset.0"].export_path).toBe("out/x.apk");
  });

  test("exportPresetCfg throws without id or name", () => {
    expect(() => exportPresetCfg({ id: "x" })).toThrow(/name|id/);
    expect(() => exportPresetCfg({ name: "X" })).toThrow(/id|name/);
  });

  test("exportPresetCfg rejects a name with a .cfg-unsafe character", () => {
    expect(() => exportPresetCfg({ id: "x", name: 'My "Cool" Game' })).toThrow(/unsafe|quote/);
    expect(() => exportPresetCfg({ id: "x", name: "Two\nLines" })).toThrow(/unsafe|newline/);
  });

  test("bootSplashCfg rejects an image path with a .cfg-unsafe character", () => {
    expect(() => bootSplashCfg({ image: 'res://"x".png' })).toThrow(/unsafe|quote/);
  });

  test("parsePresetCfg strips quotes, coerces booleans and ints", () => {
    const parsed = parsePresetCfg('[preset.0]\n\nname="Hi"\nrunnable=true\nfoo=false\nn=42\n');
    expect(parsed["preset.0"]).toEqual({ name: "Hi", runnable: true, foo: false, n: 42 });
  });

  test("parsePresetCfg skips Godot comment lines", () => {
    const parsed = parsePresetCfg('; auto-generated by Godot\n[preset.0]\nname="Hi"\n');
    expect(parsed["preset.0"]).toEqual({ name: "Hi" });
  });

  test("parsePresetCfg throws on a key before any section", () => {
    expect(() => parsePresetCfg('name="orphan"\n')).toThrow(/section/);
  });

  test("parsePresetCfg throws on an unparseable line", () => {
    expect(() => parsePresetCfg("[preset.0]\nthis line has no equals\n")).toThrow(/unparseable/);
  });
});

describe("splashSize", () => {
  test("returns the canonical portrait boot-splash dimensions", () => {
    expect(splashSize()).toEqual({ w: 1080, h: 1920 });
  });

  test("returns a fresh object each call (not a shared mutable singleton)", () => {
    expect(splashSize()).not.toBe(splashSize());
  });

  test("splashSize('portrait') is 1080x1920", () => {
    expect(splashSize("portrait")).toEqual({ w: 1080, h: 1920 });
  });

  test("splashSize('landscape') swaps to 1920x1080", () => {
    expect(splashSize("landscape")).toEqual({ w: 1920, h: 1080 });
  });
});

describe("bootSplashCfg + parsePresetCfg", () => {
  test("generates an [application] boot_splash block that round-trips through the parser", () => {
    const cfg = bootSplashCfg({ image: "res://store/splash.png" });
    const parsed = parsePresetCfg(cfg);
    expect(parsed.application["application/boot_splash/image"]).toBe("res://store/splash.png");
    expect(parsed.application["application/boot_splash/show_image"]).toBe(true);
    expect(parsed.application["application/boot_splash/fullsize"]).toBe(true);
  });

  test("honors show_image=false", () => {
    const parsed = parsePresetCfg(bootSplashCfg({ image: "res://store/splash.png", showImage: false }));
    expect(parsed.application["application/boot_splash/show_image"]).toBe(false);
  });

  test("throws without an image path", () => {
    expect(() => bootSplashCfg({})).toThrow(/image/);
  });
});

describe("atlasLayout", () => {
  // No two placements may overlap (axis-aligned rectangle intersection test).
  function anyOverlap(placements) {
    for (let i = 0; i < placements.length; i++) {
      for (let j = i + 1; j < placements.length; j++) {
        const a = placements[i], b = placements[j];
        const sep = a.x + a.w <= b.x || b.x + b.w <= a.x || a.y + a.h <= b.y || b.y + b.h <= a.y;
        if (!sep) return true;
      }
    }
    return false;
  }

  test("packs a single rect at the origin in a power-of-two sheet", () => {
    const out = atlasLayout([{ name: "hero", w: 100, h: 80 }]);
    expect(out.placements).toEqual([{ name: "hero", x: 0, y: 0, w: 100, h: 80 }]);
    expect(out.sheet.w).toBe(128);
    expect(out.sheet.h).toBe(128);
  });

  test("places every rect with no overlap and inside the sheet", () => {
    const rects = [
      { name: "a", w: 200, h: 200 }, { name: "b", w: 150, h: 100 },
      { name: "c", w: 300, h: 120 }, { name: "d", w: 64, h: 64 }
    ];
    const out = atlasLayout(rects, { maxWidth: 512 });
    expect(out.placements).toHaveLength(rects.length);
    expect(out.placements.map((p) => p.name).sort()).toEqual(["a", "b", "c", "d"]);
    expect(anyOverlap(out.placements)).toBe(false);
    for (const p of out.placements) {
      expect(p.x + p.w).toBeLessThanOrEqual(out.sheet.w);
      expect(p.y + p.h).toBeLessThanOrEqual(out.sheet.h);
    }
  });

  test("is deterministic — identical input yields identical output", () => {
    const rects = [{ name: "a", w: 90, h: 40 }, { name: "b", w: 90, h: 40 }, { name: "c", w: 30, h: 70 }];
    expect(atlasLayout(rects, { maxWidth: 128 })).toEqual(atlasLayout(rects, { maxWidth: 128 }));
  });

  test("empty input yields an empty sheet", () => {
    expect(atlasLayout([])).toEqual({ sheet: { w: 0, h: 0 }, placements: [] });
  });

  test("throws when a rect is wider than maxWidth", () => {
    expect(() => atlasLayout([{ name: "wide", w: 2000, h: 10 }], { maxWidth: 1024 })).toThrow(/maxWidth|wide/);
  });

  test("throws on a malformed rect", () => {
    expect(() => atlasLayout([{ name: "a", w: 10 }])).toThrow(/w.*h|h/);
  });
});

// verify() is Method 5's packaging gate; budgetReport() sums the store dir.
// Both run WITHOUT Godot (they read committed PNGs/JSON via pngSize/readFileSync),
// so every branch is reachable headlessly with a tmp fixture — exercised here.
describe("verify (packaging gate)", () => {
  // pngSize reads only the first 24 bytes, so a 24-byte IHDR header is a valid fixture.
  function writePng(path, w, h) {
    const buf = Buffer.alloc(24);
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(buf, 0);
    buf.writeUInt32BE(13, 8);
    buf.write("IHDR", 12, "latin1");
    buf.writeUInt32BE(w, 16);
    buf.writeUInt32BE(h, 20);
    writeFileSync(path, buf);
  }

  // Lay down a complete, passing store fixture under <gamesDir>/<id>/; return the store_pass.
  function buildFixture(gamesDir, id) {
    const game = join(gamesDir, id);
    const iconsDir = join(game, "store", "icons");
    mkdirSync(iconsDir, { recursive: true });
    const icons = iconSizeTable().map((e) => {
      writePng(join(iconsDir, `${e.name}.png`), e.px, e.px);
      return { name: e.name, px: e.px, kind: e.kind, source: `store/icons/${e.name}.png` };
    });
    writePng(join(game, "store", "atlas.png"), 256, 256);
    writeFileSync(join(game, "store", "atlas.json"), JSON.stringify({ placements: [{ name: "a" }, { name: "b" }] }));
    const { w, h } = splashSize();
    writePng(join(game, "store", "splash.png"), w, h);
    writeFileSync(join(game, "export_presets.cfg"), exportPresetCfg({ id, name: "Fixture" }));
    return {
      icons,
      atlas: { sheet: "store/atlas.png", map: "store/atlas.json", sprite_count: 2 },
      splash: { source: "store/splash.png", show_image: true },
      size_budget: { total_bytes: 100, budget_bytes: 1000, pass: true, per_file: [] },
      export_preset: { path: "export_presets.cfg", platform: "android", package: `com.gameforge.${id}` },
      icon_master: "art/hero.png"
    };
  }

  function manifestFor(store_pass, { withPasses = true } = {}) {
    const m = { id: "fix-0001", status: "scored", store_pass };
    if (withPasses) { m.asset_pass = { method: "raster" }; m.audio_pass = { method: "audio" }; }
    return m;
  }

  function withFixture(fn) {
    const dir = mkdtempSync(join(tmpdir(), "gf-pkg-"));
    try { fn(dir, buildFixture(dir, "fix-0001")); }
    finally { rmSync(dir, { recursive: true, force: true }); }
  }

  test("a complete, correctly-sized store passes with no issues and both passes present", () => {
    withFixture((dir, sp) => {
      const r = verify("fix-0001", { gamesDir: dir, manifest: manifestFor(sp) });
      expect(r.issues).toEqual([]);
      expect(r.file_checks_pass).toBe(true);
      expect(r.both_passes_present).toBe(true);
    });
  });

  test("a wrong-sized icon is flagged", () => {
    withFixture((dir, sp) => {
      writePng(join(dir, "fix-0001", "store", "icons", "ic_launcher_xxxhdpi.png"), 10, 10); // should be 192
      const r = verify("fix-0001", { gamesDir: dir, manifest: manifestFor(sp) });
      expect(r.file_checks_pass).toBe(false);
      expect(r.issues.join(" ")).toMatch(/ic_launcher_xxxhdpi is 10x10, expected 192/);
    });
  });

  test("a missing icon is flagged", () => {
    withFixture((dir, sp) => {
      rmSync(join(dir, "fix-0001", "store", "icons", "ic_play_store.png"));
      const r = verify("fix-0001", { gamesDir: dir, manifest: manifestFor(sp) });
      expect(r.issues.join(" ")).toMatch(/ic_play_store/);
    });
  });

  test("an atlas sprite_count mismatch is flagged", () => {
    withFixture((dir, sp) => {
      sp.atlas.sprite_count = 5; // fixture map has 2 placements
      const r = verify("fix-0001", { gamesDir: dir, manifest: manifestFor(sp) });
      expect(r.issues.join(" ")).toMatch(/atlas map covers 2 sprites, store_pass says 5/);
    });
  });

  test("a wrong-sized splash is flagged", () => {
    withFixture((dir, sp) => {
      writePng(join(dir, "fix-0001", "store", "splash.png"), 100, 100);
      const r = verify("fix-0001", { gamesDir: dir, manifest: manifestFor(sp) });
      expect(r.issues.join(" ")).toMatch(/splash is 100x100/);
    });
  });

  test("a failing size budget is flagged", () => {
    withFixture((dir, sp) => {
      sp.size_budget = { total_bytes: 2000, budget_bytes: 1000, pass: false, per_file: [] };
      const r = verify("fix-0001", { gamesDir: dir, manifest: manifestFor(sp) });
      expect(r.issues.join(" ")).toMatch(/size budget fails/);
    });
  });

  test("a non-Android export preset is flagged", () => {
    withFixture((dir, sp) => {
      writeFileSync(join(dir, "fix-0001", "export_presets.cfg"), '[preset.0]\n\nplatform="iOS"\n');
      const r = verify("fix-0001", { gamesDir: dir, manifest: manifestFor(sp) });
      expect(r.issues.join(" ")).toMatch(/platform is not Android/);
    });
  });

  test("both_passes_present is false when a pass block is absent", () => {
    withFixture((dir, sp) => {
      const r = verify("fix-0001", { gamesDir: dir, manifest: manifestFor(sp, { withPasses: false }) });
      expect(r.both_passes_present).toBe(false);
      expect(r.file_checks_pass).toBe(true); // files are fine; only the passes are missing
    });
  });

  test("throws when the manifest has no store_pass", () => {
    withFixture((dir) => {
      expect(() => verify("fix-0001", { gamesDir: dir, manifest: { id: "fix-0001", status: "scored" } }))
        .toThrow(/no store_pass/);
    });
  });

  test("a well-formed build_artifact record passes verify() with no new issue", () => {
    withFixture((dir, sp) => {
      sp.build_artifact = { format: "apk", build_type: "debug", path: "build/fix-0001-debug.apk", bytes: 1000, package: "com.gameforge.fix-0001" };
      const r = verify("fix-0001", { gamesDir: dir, manifest: manifestFor(sp) });
      expect(r.file_checks_pass).toBe(true);
    });
  });

  test("a malformed build_artifact record (bad format) is flagged by verify()", () => {
    withFixture((dir, sp) => {
      sp.build_artifact = { format: "exe", build_type: "debug", path: "build/x" };
      const r = verify("fix-0001", { gamesDir: dir, manifest: manifestFor(sp) });
      expect(r.issues.join(" ")).toMatch(/build_artifact.*format|format/);
    });
  });
});

describe("budgetReport", () => {
  test("sums committed store bytes against the budget", () => {
    const dir = mkdtempSync(join(tmpdir(), "gf-bud-"));
    try {
      const storeDir = join(dir, "g-0001", "store");
      mkdirSync(storeDir, { recursive: true });
      writeFileSync(join(storeDir, "a.png"), Buffer.alloc(300));
      writeFileSync(join(storeDir, "b.png"), Buffer.alloc(700));
      const r = budgetReport("g-0001", { gamesDir: dir, budgetBytes: 1000 });
      expect(r.total_bytes).toBe(1000);
      expect(r.pass).toBe(true);
      expect(r.per_file.map((f) => f.path).sort()).toEqual(["store/a.png", "store/b.png"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("fails when the store exceeds the budget", () => {
    const dir = mkdtempSync(join(tmpdir(), "gf-bud-"));
    try {
      const storeDir = join(dir, "g-0001", "store");
      mkdirSync(storeDir, { recursive: true });
      writeFileSync(join(storeDir, "big.png"), Buffer.alloc(2000));
      expect(budgetReport("g-0001", { gamesDir: dir, budgetBytes: 1000 }).pass).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("exportPresetCfg format/buildType variants", () => {
  test("debug+apk preset names the prebuilt-template path (gradle off)", () => {
    const parsed = parsePresetCfg(exportPresetCfg({ id: "creature-0001", name: "Glade Spirit", format: "apk", buildType: "debug" }));
    expect(parsed["preset.0"].platform).toBe("Android");
    expect(parsed["preset.0"].name).toBe("Glade Spirit");
    expect(parsed["preset.0"].export_path).toBe("build/creature-0001-debug.apk");
    expect(parsed["preset.0.options"]["gradle_build/use_gradle_build"]).toBe(false);
    expect(parsed["preset.0.options"]["gradle_build/export_format"]).toBe(0); // 0 = APK
  });

  test("release+aab preset turns gradle build on and targets a .aab path", () => {
    const parsed = parsePresetCfg(exportPresetCfg({ id: "creature-0001", name: "Glade Spirit", format: "aab", buildType: "release" }));
    expect(parsed["preset.0"].export_path).toBe("build/creature-0001-release.aab");
    expect(parsed["preset.0.options"]["gradle_build/use_gradle_build"]).toBe(true);
    expect(parsed["preset.0.options"]["gradle_build/export_format"]).toBe(1); // 1 = AAB; without this Godot rejects the .aab path as "APK requires *.apk"
  });

  test("presetIndex emits a [preset.N] section with that index", () => {
    const parsed = parsePresetCfg(exportPresetCfg({ id: "x-0001", name: "X", presetIndex: 1 }));
    expect(parsed["preset.1"]).toBeDefined();
    expect(parsed["preset.1"].platform).toBe("Android");
    expect(parsed["preset.1.options"]).toBeDefined();
  });

  test("throws on an unknown format or buildType", () => {
    expect(() => exportPresetCfg({ id: "x", name: "X", format: "ipa" })).toThrow(/format/);
    expect(() => exportPresetCfg({ id: "x", name: "X", buildType: "beta" })).toThrow(/buildType/);
  });

  test("defaults are unchanged (debug apk, preset.0) — back-compat", () => {
    const parsed = parsePresetCfg(exportPresetCfg({ id: "creature-0001", name: "Glade Spirit" }));
    expect(parsed["preset.0"].export_path).toBe("build/creature-0001-debug.apk");
    expect(parsed["preset.0.options"]["package/unique_name"]).toBe("com.gameforge.creature_0001");
  });
});

describe("exportPresetsFile", () => {
  test("emits BOTH a debug-APK preset.0 and a release-AAB preset.1", () => {
    const parsed = parsePresetCfg(exportPresetsFile({ id: "creature-0001", name: "Glade Spirit" }));
    expect(parsed["preset.0"].name).toBe("Glade Spirit");
    expect(parsed["preset.0"].export_path).toBe("build/creature-0001-debug.apk");
    expect(parsed["preset.0.options"]["gradle_build/use_gradle_build"]).toBe(false);
    expect(parsed["preset.0.options"]["gradle_build/export_format"]).toBe(0);
    expect(parsed["preset.1"].name).toBe("Glade Spirit Release");
    expect(parsed["preset.1"].export_path).toBe("build/creature-0001-release.aab");
    expect(parsed["preset.1.options"]["gradle_build/use_gradle_build"]).toBe(true);
    expect(parsed["preset.1.options"]["gradle_build/export_format"]).toBe(1);
    expect(parsed["preset.1.options"]["package/unique_name"]).toBe("com.gameforge.creature_0001");
  });

  test("both presets share the package unique_name", () => {
    const parsed = parsePresetCfg(exportPresetsFile({ id: "x-0001", name: "X" }));
    expect(parsed["preset.0.options"]["package/unique_name"]).toBe("com.gameforge.x_0001");
    expect(parsed["preset.1.options"]["package/unique_name"]).toBe("com.gameforge.x_0001");
  });

  test("throws without id or name", () => {
    expect(() => exportPresetsFile({ id: "x-0001" })).toThrow(/name|id/);
    expect(() => exportPresetsFile({ name: "X" })).toThrow(/id|name/);
  });
});

describe("buildArtifactPlan (pure)", () => {
  test("debug+apk → --export-debug, the game preset name, a build/<id>-debug.apk out path", () => {
    const plan = buildArtifactPlan({ id: "creature-0001", name: "Glade Spirit", gamesDir: "/g" });
    expect(plan.format).toBe("apk");
    expect(plan.build_type).toBe("debug");
    expect(plan.preset).toBe("Glade Spirit");
    expect(plan.package).toBe("com.gameforge.creature_0001");
    expect(plan.outPath).toBe(join("/g", "creature-0001", "build", "creature-0001-debug.apk"));
    expect(plan.args).toEqual([
      "--headless", "--path", join("/g", "creature-0001"),
      "--export-debug", "Glade Spirit", plan.outPath
    ]);
  });

  test("release+aab → --export-release, the '<name> Release' preset, a .aab out path", () => {
    const plan = buildArtifactPlan({ id: "creature-0001", name: "Glade Spirit", format: "aab", buildType: "release", gamesDir: "/g" });
    expect(plan.preset).toBe("Glade Spirit Release");
    expect(plan.outPath).toBe(join("/g", "creature-0001", "build", "creature-0001-release.aab"));
    expect(plan.args[3]).toBe("--export-release");
    expect(plan.args[4]).toBe("Glade Spirit Release");
  });

  test("honors an explicit packageName", () => {
    expect(buildArtifactPlan({ id: "x", name: "X", packageName: "com.acme.x", gamesDir: "/g" }).package).toBe("com.acme.x");
  });

  test("throws without id or name", () => {
    expect(() => buildArtifactPlan({ id: "x", gamesDir: "/g" })).toThrow(/name|id/);
    expect(() => buildArtifactPlan({ name: "X", gamesDir: "/g" })).toThrow(/id|name/);
  });

  test("throws on an unknown format or buildType", () => {
    expect(() => buildArtifactPlan({ id: "x", name: "X", format: "ipa", gamesDir: "/g" })).toThrow(/format/);
    expect(() => buildArtifactPlan({ id: "x", name: "X", buildType: "beta", gamesDir: "/g" })).toThrow(/buildType/);
  });
});

describe("androidToolchainPresent", () => {
  test("true only when ANDROID_HOME or ANDROID_SDK_ROOT is set", () => {
    const save = { home: process.env.ANDROID_HOME, root: process.env.ANDROID_SDK_ROOT };
    try {
      delete process.env.ANDROID_HOME; delete process.env.ANDROID_SDK_ROOT;
      expect(androidToolchainPresent()).toBe(false);
      process.env.ANDROID_HOME = "C:/fake/sdk";
      expect(androidToolchainPresent()).toBe(true);
      delete process.env.ANDROID_HOME; process.env.ANDROID_SDK_ROOT = "C:/fake/sdk";
      expect(androidToolchainPresent()).toBe(true);
    } finally {
      if (save.home === undefined) delete process.env.ANDROID_HOME; else process.env.ANDROID_HOME = save.home;
      if (save.root === undefined) delete process.env.ANDROID_SDK_ROOT; else process.env.ANDROID_SDK_ROOT = save.root;
    }
  });
});

describe("buildArtifact (guarded)", () => {
  test("skips cleanly when the toolchain is absent (no spawn)", () => {
    const r = buildArtifact("creature-0001", { present: false });
    expect(r.skipped).toBe(true);
    expect(r.reason).toMatch(/ANDROID_HOME|toolchain/i);
  });
});

describe("verifyBuildArtifact (guarded)", () => {
  test("skips when the toolchain is absent", () => {
    expect(verifyBuildArtifact("creature-0001", { present: false }).skipped).toBe(true);
  });

  test("passes for a present file whose first bytes are the ZIP magic PK\\x03\\x04", () => {
    const dir = mkdtempSync(join(tmpdir(), "gf-apk-"));
    try {
      const buildDir = join(dir, "creature-0001", "build");
      mkdirSync(buildDir, { recursive: true });
      const apk = join(buildDir, "creature-0001-debug.apk");
      // ZIP local-file-header magic + padding to clear the size floor.
      writeFileSync(apk, Buffer.concat([Buffer.from([0x50, 0x4b, 0x03, 0x04]), Buffer.alloc(2048)]));
      const r = verifyBuildArtifact("creature-0001", {
        gamesDir: dir, present: true,
        build_artifact: { format: "apk", build_type: "debug", path: "build/creature-0001-debug.apk", bytes: 2052, package: "com.gameforge.creature-0001" }
      });
      expect(r.skipped).toBeUndefined();
      expect(r.ok).toBe(true);
      expect(r.signature_ok).toBe(true);
      expect(r.issues).toEqual([]);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  test("flags a missing file and a bad signature", () => {
    const dir = mkdtempSync(join(tmpdir(), "gf-apk-"));
    try {
      const buildDir = join(dir, "creature-0001", "build");
      mkdirSync(buildDir, { recursive: true });
      writeFileSync(join(buildDir, "creature-0001-debug.apk"), Buffer.from("NOT A ZIP....."));
      const bad = verifyBuildArtifact("creature-0001", {
        gamesDir: dir, present: true,
        build_artifact: { format: "apk", build_type: "debug", path: "build/creature-0001-debug.apk" }
      });
      expect(bad.ok).toBe(false);
      expect(bad.issues.join(" ")).toMatch(/signature|not a zip/i);

      const missing = verifyBuildArtifact("creature-0001", {
        gamesDir: dir, present: true,
        build_artifact: { format: "aab", build_type: "release", path: "build/creature-0001-release.aab" }
      });
      expect(missing.ok).toBe(false);
      expect(missing.issues.join(" ")).toMatch(/absent|not found/i);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
});

describe("packageNameFor", () => {
  test("replaces hyphens with underscores so the package is Android-legal", () => {
    expect(packageNameFor("creature-0001")).toBe("com.gameforge.creature_0001");
    expect(packageNameFor("crosser-0001")).toBe("com.gameforge.crosser_0001");
  });
  test("leaves an already-legal id unchanged", () => {
    expect(packageNameFor("runner")).toBe("com.gameforge.runner");
  });
  test("prefixes a letter when the sanitized id would start with a digit", () => {
    expect(packageNameFor("0001-game")).toBe("com.gameforge.g_0001_game");
  });
});

describe("parseHexLead", () => {
  test("extracts the leading #hex from a palette entry", () => {
    expect(parseHexLead("#2fa6a0 sea-teal (primary)")).toBe("#2fa6a0");
  });
  test("trims whitespace and lowercases", () => {
    expect(parseHexLead("  #FF7B54  coral")).toBe("#ff7b54");
  });
  test("returns null when no leading hex", () => {
    expect(parseHexLead("sea-teal")).toBe(null);
    expect(parseHexLead("")).toBe(null);
  });
});

describe("resolveIconBg", () => {
  test("--bg with two stops wins", () => {
    expect(resolveIconBg({ bgArg: "#111111,#222222", manifest: {} }))
      .toEqual({ top: "#111111", bottom: "#222222" });
  });
  test("--bg with one stop sets both", () => {
    expect(resolveIconBg({ bgArg: "#abcdef", manifest: {} }))
      .toEqual({ top: "#abcdef", bottom: "#abcdef" });
  });
  test("falls back to store_pass.icon_bg", () => {
    const manifest = { store_pass: { icon_bg: "#0a0b0c,#1a1b1c" } };
    expect(resolveIconBg({ manifest })).toEqual({ top: "#0a0b0c", bottom: "#1a1b1c" });
  });
  test("derives from the asset_pass palette's first two hexes", () => {
    const manifest = { asset_pass: { visual_system: { palette: [
      "#2fa6a0 sea-teal (primary)", "#ff7b54 coral (accent)", "#8a5a3b wood"
    ] } } };
    expect(resolveIconBg({ manifest })).toEqual({ top: "#2fa6a0", bottom: "#ff7b54" });
  });
  test("single-hex palette uses it for both stops", () => {
    const manifest = { asset_pass: { visual_system: { palette: ["#2fa6a0 only"] } } };
    expect(resolveIconBg({ manifest })).toEqual({ top: "#2fa6a0", bottom: "#2fa6a0" });
  });
  test("absent everything → neutral default", () => {
    expect(resolveIconBg({ manifest: {} })).toEqual({ top: "#202830", bottom: "#202830" });
  });
});

describe("iconCompositionRole", () => {
  test("adaptive_fg → focal (transparent subject in safe zone)", () => {
    expect(iconCompositionRole("adaptive_fg")).toBe("focal");
  });
  test("adaptive_bg → background (gradient fill)", () => {
    expect(iconCompositionRole("adaptive_bg")).toBe("background");
  });
  test("launcher + play → composite (focal over bg, opaque)", () => {
    expect(iconCompositionRole("launcher")).toBe("composite");
    expect(iconCompositionRole("play")).toBe("composite");
  });
  test("every iconSizeTable kind maps to a role", () => {
    for (const e of iconSizeTable()) {
      expect(["focal", "background", "composite"]).toContain(iconCompositionRole(e.kind));
    }
  });
  test("unknown kind throws (fail loud)", () => {
    expect(() => iconCompositionRole("nope")).toThrow();
  });
});
