import { test, expect, describe } from "vitest";
import { iconSizeTable, sizeBudget, pngSize, exportPresetCfg, parsePresetCfg, atlasLayout } from "./package.mjs";

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
    expect(r.total).toBe(350);
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
    expect(sizeBudget([], 10)).toEqual({ total: 0, budget_bytes: 10, pass: true, per_file: [] });
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
    expect(parsed["preset.0.options"]["package/unique_name"]).toBe("com.gameforge.creature-0001");
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
