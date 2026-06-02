---
name: validator
description: Use when confirming a generated Godot game opens, runs, and has a working core loop. Runs headless checks, records manifest.validation, and advances status to validated/playable or failed.
---

# validator

Confirm a generated game opens, runs without script errors, and (via human playtest) has a working core loop. Make every failure **legible** — attribute it to a specific skill gap (POC success criterion #5).

## Inputs
- `manifests/<id>.json` with a populated `build` block (`status = "generated"`).
- The project on disk at `games/<id>/`.

## Outputs
- A populated `manifest.validation` block.
- `status = "validated"` (programmatic checks pass), then `"playable"` (human playtest passes), or `"failed"` with legible `issues`.

## Method 1 — Programmatic (automated now)

1. **Run the project headless** and capture output + exit code:
   ```
   godot --headless --path games/<id>/ --quit-after 120
   ```
   PASS when: exit code is 0 AND the output contains no `SCRIPT ERROR`, no `ERROR:`, and no "Failed to load" lines. (A clean run of ~120 frames means the scene tree loaded and `_process` ran without crashing.)

2. Record results:
   ```
   node tools/manifest.mjs merge <id> "{\"validation\": {\"opens_in_editor\": true, \"runs\": true, \"issues\": []}}"
   ```
   - On failure, set `runs: false` and put each error line in `issues` verbatim, then:
     ```
     node tools/manifest.mjs set-status <id> failed
     ```
     STOP and report which skill is responsible (almost always `builder`) and the precise error.

3. On a clean run, **do not advance yet** — proceed to Method 1.5. The build is structurally sound, but "runs clean" is not "plays correctly"; the logic gate decides whether it reaches `validated`.

## Method 1.5 — Logic self-test (automated; REQUIRED if `games/<id>/selftest.gd` exists)

Headless error-checking cannot catch logic bugs in logic-heavy genres (match-3, hybrids): a mis-detected match, broken gravity, or an offense action that never damages the threat all run clean and only fail a human (POC runs 002–004). `builder` now emits `games/<id>/selftest.gd` for such genres — run it:
```
godot --headless --path games/<id>/ --script res://selftest.gd
```
- **PASS** = exit code 0 AND output contains `SELFTEST OK`. Then advance:
  ```
  node tools/manifest.mjs merge <id> "{\"validation\": {\"core_loop_functional\": true}}"
  node tools/manifest.mjs set-status <id> validated
  ```
  (`core_loop_functional` is now backed by an assertion, not just a hopeful human — the human playtest in Method 2 confirms *feel*, the self-test confirms *logic*.)
- **FAIL** = `SELFTEST FAIL: <reason>` or non-zero exit. Record the reason verbatim in `issues`, set `core_loop_functional: false`, `set-status <id> failed`, and STOP — attribute it to `builder` with the precise assertion that failed (e.g. "builder: a 3-in-a-row swap did not clear any cells"). This is a POC success: a logic bug was caught automatically.
- **No `selftest.gd` for a logic-heavy genre** is itself a `builder` finding — note it ("shipped no automated proof its loop works"), then advance to `validated` on the clean run and lean harder on Method 2. For a genuinely trivial arcade loop, absence is fine.

## Method 2 — Human playtest (manual now)

4. Ask the owner to open the project in the Godot editor and play for ~60 seconds, confirming the core loop from `concept.core_loop` (e.g. tap → jump, score climbs, game-over → restart works).

5. On confirmation:
   ```
   node tools/manifest.mjs merge <id> "{\"validation\": {\"core_loop_functional\": true}}"
   node tools/manifest.mjs set-status <id> playable
   ```
   If the loop is broken, record the specific failure in `issues`, set the loop boolean false, and attribute it to a skill (e.g. "builder did not wire restart on tap after game over"). Do NOT advance to `playable`.

## Toward full automation — what's built vs. what remains

Method 1.5 above is the first half of this hook, now **live** for logic-heavy genres: `builder` emits `selftest.gd`, the validator runs it, and `SELFTEST OK` backs `core_loop_functional` with an assertion instead of a hope. What it does NOT yet do is **replace the human playtest** — the self-test proves the loop's *logic* is correct, but `playable` still requires a human to confirm it *feels* right (juice, fairness, that a blend actually coheres). The remaining future step is to grow `selftest.gd` coverage (and add feel heuristics) until `status` can reach `playable` in CI with no human in the loop. Until then: self-test gates `validated`, human gates `playable`.

## Method 3 — Re-skin re-validation (`playable → styled`, after the `asset` skill)

When `asset` has re-skinned a `playable` title — via the **`svg`** *or* the **`raster`** method — re-run the same gates on the rewired game and advance to the terminal `styled` status on success. The gates are method-agnostic:

1. **Headless import + run clean** — `godot --headless --path games/<id>/ --quit-after 120`, exit 0 with no `SCRIPT ERROR` / `ERROR:` / "Failed to load". Proves the textures (`.svg` or `.png`) imported and the rewired scene runs. (Confirm the `asset` skill ran `--import` first, or `load("res://art/...")` returns null.)
2. **`selftest.gd` still `SELFTEST OK`** (if the title has one) — proves the swap changed only visuals, not logic.
3. **Human A/B playtest** — the owner confirms the re-skin (a) looks more designed than the primitive original, (b) **reads as one coherent visual system** rather than mismatched assets, and (c) plays identically.
   - **Cross-modal cohesion (when ≥2 modalities are present — e.g. the title also carries an `audio_pass`, or at M2 a `store_pass`):** confirm the visuals, audio, and (at M2) the icon **read as one themed world** — the same premise/tone/setting from `concept.theme` — not three independent interpretations. On failure, attribute it to a **`concept.theme` gap** (the anchor was too vague to align the modalities) or to a **skill that ignored the theme** (e.g. "audio: chose a chiptune mood for a cozy-storybook theme — ignored `concept.theme.tone`") — a specific, fixable prose cause, exactly like the within-modality cohesion finding above.

**Raster-only additional checks (when `asset_pass.method == "raster"`):**
- **Mobile-density sanity** — each `recipes[].master_resolution` is a high-res power-of-two master (downscaled to footprint, never upscaled) and each `import_settings` enables mipmaps. A sprite that is blurry/aliased at the footprint, or generated below its on-screen size, is an `asset` finding (wrong master/import), not a validator pass.
- **IP-safety A/B** — the owner explicitly confirms **nothing resembles trademarked/copyrighted characters, logos, or celebrity likeness**. If anything does, it is a hard fail (app-store + legal risk): record it, attribute it to `asset` (weak `negative` prompt / non-generic prompt), and do **not** advance.

On all gates passing:
```
node tools/manifest.mjs set-status <id> styled
node tools/manifest.mjs validate <id>
```
On failure, record the specific issue in `validation.issues`, attribute it to a skill, and do **not** advance — the game stays `playable`. Examples: "asset: left the primitive obstacle drawing under the sprite — double-draw"; "asset: sprites individually fine but don't cohere — prompt_scaffold/style gap"; "asset: hero master generated at 256² — blurry on xxxhdpi, wrong master_resolution"; "comfy.mjs: ComfyUI unreachable — infra, re-run after starting the server". The fix is a specific `asset`/`comfy.mjs` prose or recipe change.

## Method 4 — Audio pass (PNG-independent; for `scored` games)

When a game carries an `audio_pass`, confirm the audio is real and wired:

1. **Files exist & import.** Every `audio_pass.recipes[].name` has a committed file at `games/<id>/audio/<name>.<format>`. Open the project headless (`& "<godot-exe>" --path games/<id>/ --quit-after 2`) and confirm Godot imports the audio without errors in the log (no "Error importing" / failed `.import`).
2. **Players reference valid streams.** Each `audio_pass.events[].node` exists as an `AudioStreamPlayer` in the scene and its `stream` points at a real imported clip; the music player's stream has `loop = true` when its recipe set `loop:true`.
3. **SFX fire on events** — *gated, like Method 1.5*. **If** `games/<id>/selftest.gd` exists and carries audio assertions, drive each mapped `signal`/event through it and assert the corresponding `AudioStreamPlayer.play()` was invoked (e.g. spy by checking `playing` or a wired counter). **Otherwise** (no selftest, or a selftest with no audio coverage — neither `builder` nor `audio` is required to add play()-spy assertions), confirm SFX wiring by inspection (item 2 already verified each player references a real stream) and move on. Don't block on a self-test no skill was told to write.
4. **Mobile sanity.** File sizes are reasonable for mobile (SFX ≪ 1 MB; music a few MB WAV — the pipeline emits uncompressed WAV today, ~5 MB / 30 s stereo; OGG is a future size optimization), formats are `wav`/`ogg`, sample rate ≤ 48 kHz.
5. **IP-safety.** Confirm no recipe prompt names an artist or copyrighted track; music negative prompt excludes vocals unless intended.
6. **Cross-modal cohesion (when the title also has an `asset_pass`).** Confirm the audio and the visuals **read as one themed world** — the same premise/tone/setting from `concept.theme`. A cozy-storybook look with an aggressive arcade soundtrack is a failure: attribute it to a `concept.theme` gap or to the `audio`/`asset` skill that ignored the theme, and record it. (Cohesion is a human judgment call, like every aesthetic gate — not automatable.) This is the **same** cross-modal question as Method 3's cohesion sub-bullet — if the visual pass already confirmed it, record the verdict once rather than re-litigating. Like the rest of Method 4, it is an advisory finding recorded in `validation.issues`, not a hard gate that blocks the visual pass.

Record results in `manifest.validation.issues` as needed. Audio validation does not block the visual pass and vice-versa.

## Method 5 — Packaging gate (`scored → packaged`, after the `packager` skill)

When `packager` has produced a `store_pass`, assert the title is genuinely store-ready — **headlessly and without the Android SDK** — then advance to the terminal `packaged` status. The CI-checkable assertions run through `tools/package.mjs verify` (pure file + dimension + parse checks; no GPU, no SDK):

```
node tools/package.mjs verify <id>
```

1. **Both polish passes present + A/B-confirmed.** A game is store-ready only with **both** a confirmed visual `asset_pass` **and** a confirmed `audio_pass` (spec §2). The gate keys off the **presence of both pass blocks** — the source of truth the `asset`/`audio` skills designate — **not** the lossy `status` string (which holds only `styled` *or* `scored` at once). The A/B *confirmation* itself is the human gate that advanced the title through `styled` (visual) and `scored` (audio): the canonical incoming status is `scored`, having passed through `styled`. If either block is absent, or the owner has not A/B-confirmed both visual and audio, **do not** advance — record "packager ran before both identities were owner-confirmed."
2. **Every icon at exact px.** Each `iconSizeTable()` entry exists at its **exact** pixel dimensions (read straight from each PNG's IHDR by `package.mjs`, no engine). A missing or wrong-sized icon is a `packager`/`package.mjs` finding.
3. **Atlas covers every member.** The atlas sheet exists and its map (`store/atlas.json`) has one placement per member sprite (`sprite_count` matches).
3b. **Splash at canonical size (if recorded).** When `store_pass.splash` is present, `store/splash.png` exists at the canonical boot-splash dimensions (`splashSize()` → 1080×1920, read from the PNG's IHDR). Splash is optional, so a themeless/splashless title still passes; a wrong-sized splash is a `package.mjs` finding. The boot_splash *aesthetic* is part of item 7's owner A/B.
4. **Size budget passes.** `store_pass.size_budget.pass` is true (total committed store bytes ≤ budget). On failure, attribute it to oversized masters or too many assets — a specific `packager` choice.
5. **Export preset parses.** `games/<id>/export_presets.cfg` exists and parses as a valid Godot Android preset (`parsePresetCfg` → `preset.0.platform == "Android"`).
6. **Regression guard.** The game still imports + runs headless clean — `godot --headless --path games/<id>/ --quit-after 120`, exit 0 with no `SCRIPT ERROR`/`ERROR:`/"Failed to load" (packaging must not have broken the game).
6b. **Build artifact (toolchain-guarded; CI-skipped).** When `store_pass.build_artifact` is recorded, `package.mjs verify` already checks its **shape** (format/build_type/path) headlessly with no SDK. When the **Android toolchain is present** (`ANDROID_HOME`/`ANDROID_SDK_ROOT` set), additionally run `node tools/package.mjs verify-build <id>` to assert the real file exists and is a well-formed APK/AAB (ZIP magic `PK\x03\x04`, non-trivial size). When the toolchain is **absent**, this command skips cleanly (prints `skipped:true`, exit 0) — the build artifact is git-ignored and never present on a clean checkout, so CI is unaffected. A recorded-but-broken artifact is a `packager`/`package.mjs` finding.
7. **Cross-modal cohesion A/B (human).** The owner confirms the visuals, audio, **and the store icon/splash/screenshots** read as **one themed world** — the same premise/tone/setting from `concept.theme` — not four independent interpretations. (This is the M2 cohesion check the theming precursor explicitly deferred to here.) On failure, attribute it to a **`concept.theme` gap** (anchor too vague) or to the **skill that ignored the theme** (e.g. "packager: chose a hard-neon icon for a cozy-storybook theme — ignored `concept.theme.tone`") — a specific, fixable prose cause.

On all gates passing:
```
node tools/manifest.mjs set-status <id> packaged
node tools/manifest.mjs validate <id>
```
On failure, record the specific issue in `validation.issues`, attribute it to a skill (`packager` / `package.mjs`), and do **not** advance — the game stays `scored`. The **icon/splash aesthetic A/B** (item 7's aesthetic verdict) and the **real APK build** are explicitly the owner gate and the **§8 Android-toolchain feasibility gate** — not asserted here. The end-to-end `… → packaged` proof needs a `scored` game (owner-gated) plus the APK gate; the foundation exercises the CI-checkable assertions against the current substrate without claiming `packaged` (spec §9). Note (Android-shippable POC, 2026-06-02): proving the **build toolchain** on a game — recording `build_artifact` and passing `verify-build` — does **not** by itself advance status to `packaged`. The `packaged` gate still requires both owner A/B confirmations (`styled` visual + `scored` audio) and the item-7 cross-modal cohesion A/B. A game whose build is proven but whose A/Bs are still pending (e.g. creature-0001) stays at its current status. The build seam proves shippability of the *pipeline*, not polish of the *game*.

## Notes
- Some Godot CLI flags vary slightly by 4.x point release; if `--quit-after` is unavailable, fall back to `--headless --path games/<id>/ --quit` after confirming `--import` succeeds. Verify against the pinned version.
- Legibility is the product. "It didn't work" is a POC failure; "builder doesn't scaffold touch input" is a POC success.
