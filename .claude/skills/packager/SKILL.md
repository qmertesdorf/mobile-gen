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
- `games/<id>/store/screenshots/*.png` — gameplay frames at Play dimensions.
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
node tools/package.mjs budget <id>       # sum store assets vs the budget
node tools/package.mjs preset <id>       # print the Android export_presets.cfg (redirect into games/<id>/export_presets.cfg)
```

Then record `store_pass` (arrays replace wholesale — pass the full set):

```
node tools/manifest.mjs merge <id> "{\"store_pass\": { \"icon_master\": \"art/<hero>.png\", \"icons\": [ … ], \"splash\": { … }, \"screenshots\": [ … ], \"atlas\": { … }, \"size_budget\": { … }, \"export_preset\": { \"path\": \"export_presets.cfg\", \"platform\": \"android\", \"package\": \"com.gameforge.<id>\" }, \"notes\": \"…\" }}"
node tools/manifest.mjs validate <id>
```

## Hard requirements & honesty

- **Headless vs real renderer.** Icon resize + atlas composite use Godot's `Image` API and run **headless**. Screenshots **must not** be headless — the dummy renderer captures no pixels; `package.mjs` runs the harness on the real Vulkan renderer (see the `asset` raster note + `godot-binary-path`).
- **Mobile density.** Every launcher density comes from **downscaling** the high-res master, never upscaling — that is the app-store readiness the raster masters were sized for.
- **IP safety.** The icon/splash/screenshots inherit the art's IP posture; do not introduce franchise/character/studio likenesses. The owner aesthetic A/B is the final IP review (same as `asset`).
- **Do not** edit `concept`, `builder`, `asset`, or `audio`. Consume `concept.theme` + the two pass blocks as-is.
- **Do not** set `packaged` — hand to `validator`.

## Deferred (named gates — track, do not fake)

- **Actual APK build** (`godot --headless --export-debug "Android" …`) → the **Android-toolchain feasibility gate** (spec §8): needs the Android SDK + JDK (`ANDROID_HOME` unset here). Same shape as the ComfyUI (M1.5) and Stable-Audio (M1.6) gates — stood up once, a single decisive pass/fail.
- **Icon/splash aesthetic A/B + real store submission** (account, signing keys, listing copy, legal) → owner-gated, like every art/audio A/B.

## Hand off to the validator

Hand off to `validator`, which runs **Method 5 — packaging gate** (both pass blocks present + A/B-confirmed; every icon at its exact px; atlas map covers every member; budget passes; export preset parses; headless run still clean; cross-modal cohesion A/B) and advances `scored → packaged` on success, or records legible `issues` (attributed to `packager`/`package.mjs`) and stops.
