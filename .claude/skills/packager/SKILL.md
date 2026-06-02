---
name: packager
description: Use when turning a fully-polished Godot title (both a confirmed visual asset_pass AND audio_pass) into the inputs an Android store build needs — launcher icons at every density, the Play 512 + adaptive layers, a boot splash, gameplay screenshots, a texture atlas, an asset size-budget report, and an Android export preset. Derives the packaging set from concept.theme, records store_pass, and hands off to validator's packaging gate for "packaged".
---

# packager

Turn a folder of mobile-grade assets into the **inputs a shippable Android build needs**, with the same legible-attribution discipline as every prior milestone: a re-runnable tool (`tools/package.mjs` + the `tools/godot/` pixel scripts) that derives the packaging set from the manifest, records it in `store_pass`, and is gated by `validator` Method 5. This runs as a title-level bolt-on **after** a game has both its visual and audio identity:

```
… → asset → [styled] → audio → [scored] → packager → validator(Method 5) → [packaged]
                                                                                 └→ (later) APK feasibility gate → store submission (owner)
```

## Inputs (both polish passes required)

- `manifests/<id>.json` carrying **both** an `asset_pass` (visual identity, owner A/B-confirmed → the game reached `styled`) **and** an `audio_pass` (audio identity, owner A/B-confirmed → the game reached `scored`). A primitive-art or silent game is **not** store-ready — both identities are mandatory (spec §2). The canonical incoming status is `scored`.
- The game on disk at `games/<id>/`, with its committed raster art under `games/<id>/art/`.
- The pinned Godot from `README.md` (`tools/package.mjs` spawns it for the pixel ops). ComfyUI is **not** needed here — packaging reuses art that already exists.

## Outputs

- `games/<id>/store/icons/*.png` — every `iconSizeTable()` entry (launcher mdpi→xxxhdpi, Play 512, adaptive fg/bg 432).
- `games/<id>/store/atlas.png` + `games/<id>/store/atlas.json` — the texture atlas + coordinate map.
- `games/<id>/store/screenshots/*.png` — gameplay frames at the game's portrait resolution (the tool saves whatever the running game renders — `builder` ships 720×1280; it does not resize to a fixed Play-store target).
- `games/<id>/store/splash.png` (and the Godot `boot_splash` config).
- `games/<id>/export_presets.cfg` — a valid Android export preset.
- A populated `store_pass` block (icons, splash, screenshots, atlas, size_budget, export_preset, icon_master, notes).
- Hand-off to `validator` — **do not** set `packaged` yourself.

## Step 0 — Derive the packaging set FIRST (the real deliverable)

Like `asset`/`audio` Step 0, write the packaging decisions down **before** generating anything, anchored to `concept.theme` (premise/tone/mood_keywords/setting — the same modality-neutral world the visuals and audio express). The icon, splash, and screenshots are the title's **store face**; they must read as *that theme's world*, not a fourth independent interpretation. Decide and record verbatim in `store_pass`:

- **Icon master** — the styled hero/character sprite that best represents the theme (e.g. the painterly forest-spirit for a cozy-woodland title), or a deliberately-composed master. Record it as `store_pass.icon_master` (a path under `games/<id>/`). For this **foundation** the master is *derived from an existing sprite*; the **final** icon/splash art is an **owner aesthetic A/B**, recorded as deferred in `notes` (the inverse of `asset`'s "flag what SVG does badly").
- **Splash** — the boot image and whether to show it.
- **Screenshots** — which gameplay moments read best in a store listing (e.g. a mid-combo frame, a near-miss).
- **Atlas membership** — which sprite PNGs pack into the atlas.
- **Size budget** — the per-title byte budget (default 50 MiB; override via `GAMEFORGE_SIZE_BUDGET` or the tool opt).

## Flow

Run the tool (it pairs the pure JS seam with the Godot pixel scripts, exactly like `comfy.mjs`):

```
node tools/package.mjs icons <id>        # resize the icon master into every density (headless Image)
node tools/package.mjs atlas <id>        # pack art/*.png → store/atlas.png + atlas.json (headless Image)
node tools/package.mjs screenshot <id> <name> [frames]   # capture a play frame on the REAL renderer (not headless)
node tools/package.mjs splash <id> [#RRGGBBAA]   # composite the icon master onto a themed bg → store/splash.png (headless Image); pick the bg from concept.theme
node tools/package.mjs budget <id>       # sum store assets vs the budget (run AFTER icons/atlas/screenshot/splash so it includes them)
node tools/package.mjs preset <id>       # print the Android export_presets.cfg (redirect into games/<id>/export_presets.cfg)
node tools/package.mjs build <id>            # build the debug APK via headless Godot (toolchain-guarded: skips with exit 3 if ANDROID_HOME unset)
node tools/package.mjs build <id> --release --aab   # build the signed release AAB (needs tools/android-signing.local.json)
```

Then record `store_pass` (arrays replace wholesale — pass the full set):

```
node tools/manifest.mjs merge <id> "{\"store_pass\": { \"icon_master\": \"art/<hero>.png\", \"icons\": [ … ], \"splash\": { … }, \"screenshots\": [ … ], \"atlas\": { … }, \"size_budget\": { … }, \"export_preset\": { \"path\": \"export_presets.cfg\", \"platform\": \"android\", \"package\": \"com.gameforge.<id>\" }, \"build_artifact\": { … }, \"notes\": \"…\" }}"
node tools/manifest.mjs validate <id>
```

Record `store_pass.build_artifact` from the `build` command's JSON (format, build_type, path, bytes, package). If the build skipped (exit 3, no Android toolchain), omit `build_artifact` and note the deferred toolchain gate — do not fabricate a record.

## Hard requirements & honesty

- **Headless vs real renderer.** Icon resize + atlas composite use Godot's `Image` API and run **headless**. Screenshots **must not** be headless — the dummy renderer captures no pixels; `package.mjs` runs the harness on the real Vulkan renderer (see the `asset` raster note + `godot-binary-path`).
- **Recording screenshots — assemble the schema shape, don't paste tool output.** `package.mjs screenshot` returns `{name, source, path}`, but `store_pass.screenshots[]` records `{name, px, source}` (schema-validated). When you merge, **drop the tool's `path`** (it's an absolute disk path) and **add `px`** as the captured `"WxH"` (e.g. `"720x1280"`). Pasting the tool's object verbatim fails the very next `validate` step (extra `path`, missing `px`).
- **Mobile density.** Every launcher density comes from **downscaling** the high-res master, never upscaling — that is the app-store readiness the raster masters were sized for.
- **Boot splash.** `splash` composites the icon master (~60%, centered) onto a themed solid background at the canonical portrait size (`splashSize()` → 1080×1920) and returns the `boot_splash_cfg` block for `project.godot`'s `[application]` section. `store_pass.splash` records only `{source, show_image}`; splicing `boot_splash_cfg` into the game's `project.godot` is applied at **real-package time** alongside the export preset (the foundation commits the asset + record, not the runtime project change). A splash composited from a master with an opaque background will show that background — for the final art, prefer a transparent-bg master or a deliberately-composed splash (the deferred owner aesthetic A/B).
- **IP safety.** The icon/splash/screenshots inherit the art's IP posture; do not introduce franchise/character/studio likenesses. The owner aesthetic A/B is the final IP review (same as `asset`).
- **Do not** edit `concept`, `builder`, `asset`, or `audio`. Consume `concept.theme` + the two pass blocks as-is.
- **Do not** set `packaged` — hand to `validator`.

## Deferred (named gates — track, do not fake)

- **APK/AAB build is now in scope** (no longer deferred): `node tools/package.mjs build <id>` shells out to headless Godot, guarded by `ANDROID_HOME`. On a toolchain-equipped machine it produces a debug APK (and `--release --aab` a signed AAB) and records `store_pass.build_artifact`. Without the SDK it skips cleanly (exit 3) — the same no-GPU/no-ComfyUI posture. The one-time machine setup (debug keystore, Godot editor SDK path, AVD) is documented in `README.md` → "Android export" + `tools/android-setup.ps1`.
- **Real store submission** (Play developer account, release-keystore custody, listing copy, content rating, legal) → owner-gated. The signed AAB is built locally now; uploading it is the owner step documented in `docs/superpowers/specs/2026-06-02-play-console-submission.md`.
- **Icon/splash aesthetic A/B** → owner-gated, like every art/audio A/B.

## Hand off to the validator

Hand off to `validator`, which runs **Method 5 — packaging gate** (both pass blocks present + A/B-confirmed; every icon at its exact px; atlas map covers every member; budget passes; export preset parses; headless run still clean; cross-modal cohesion A/B) and advances `scored → packaged` on success, or records legible `issues` (attributed to `packager`/`package.mjs`) and stops.
