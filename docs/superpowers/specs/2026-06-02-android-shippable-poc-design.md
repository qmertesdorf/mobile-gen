# Android-shippable POC — design

**Date:** 2026-06-02
**Status:** approved (brainstorming) → writing plan
**Target game:** `creature-0001` (furthest along: `asset_pass` + `audio_pass` + full `store_pass` already committed; valid `export_presets.cfg` present)

## Goal

Close the long-deferred **Android-toolchain gate** so a GameForge Godot POC is provably shippable to Android, and **codify the build step into the repo tooling** so it survives the upcoming (separate-milestone) game-creation overhaul. The build/ship pipeline is orthogonal to game quality, so it is durable work regardless of how game generation changes.

**Explicitly out of scope:** the game-creation overhaul itself; improving creature-0001's art/audio; actual Play Store submission (no developer account assumed yet).

## Decisions (locked during brainstorming)

1. **Target artifact — both, phased.**
   - **Phase A (the POC gate):** a **debug APK** that installs and runs.
   - **Phase B:** a **release keystore + signed `.aab`** built locally, plus a documented Play Console submission path. Phase B *builds* the signed AAB now; *submission* is deferred to when the owner has a Play account.
2. **Verification surface:** **Android emulator (AVD)** — no physical device required. Install via `adb`, launch, eyeball/screenshot the running game.
3. **Scope:** **codify into tooling** — a real Godot-export seam in `tools/package.mjs`, a build step in the `packager` skill, a README Android section, and an additive `store_pass.build_artifact` manifest field — *and* prove it end-to-end on creature-0001.

## Machine state (already verified 2026-06-02)

Present: Android SDK at `C:\Users\quint\AppData\Local\Android\Sdk` (platform-tools/`adb`, `emulator`, build-tools 33.0.1, platforms android-31 & android-33-ext4, system-images), Godot 4.6.3.stable export templates, Microsoft OpenJDK 21.

Gaps to fill during setup: `ANDROID_HOME`/`ANDROID_SDK_ROOT` unset; `adb`/`emulator` not on PATH; **no debug keystore** (`~/.android/debug.keystore` absent); **no AVD created**; Godot editor settings not yet pointed at the SDK/keystore for headless CLI export.

## Chosen approach

**Thin spawn-seam in `package.mjs`, toolchain-guarded** (over Gradle custom-build and a standalone external script). It mirrors the existing pattern where `generateIcons`/`generateAtlas`/`generateSplash` shell out to headless Godot. A *pure* planner is unit-tested; the spawn is the impure edge, exactly like the existing GPU/ComfyUI steps. The Gradle custom-build path is YAGNI until native plugins are needed; a separate script would fracture the "`package.mjs` is the seam" convention.

## Design

### 1. One-time environment setup (machine config — documented, not committed binaries)

Captured in a new **README "Android export" section** plus a reproducible helper (PowerShell) so it is not tribal knowledge:

- **Debug keystore:** `keytool` (JDK 21) generates `~/.android/debug.keystore` with Godot's expected `androiddebugkey / android / android`.
- **Point Godot at the SDK + keystore for headless export:** set `export/android/android_sdk_path` and the debug-keystore keys in Godot's editor settings (`%APPDATA%\Godot\editor_settings-4.tres`). CLI export reads these; without them the export aborts.
- **AVD:** confirm a usable system-image, create an AVD via `avdmanager`, boot via `emulator`.

### 2. Build seam + schema (durable repo code)

- **`tools/package.mjs`:**
  - pure `buildArtifactPlan({ id, format, buildType, gamesDir })` → `{ cmd, args, outPath, package, preset }` — unit-testable, no SDK touched.
  - impure `buildArtifact(id, opts)` — spawns headless Godot (`--export-debug` / `--export-release` for the `"Android"` preset), returns `{ path, bytes, exit, format, build_type, package }`.
  - extend `exportPresetCfg()` so it can emit the **release / AAB** variant in addition to today's debug-APK preset.
- **`schema/manifest.schema.json`:** additive optional `store_pass.build_artifact`:
  `{ format: "apk"|"aab", build_type: "debug"|"release", path, bytes, package }`.
- **CLI:** `node tools/package.mjs build <id> [--release] [--aab]`.

### 3. CI-safety (hard constraint)

`vitest` runs with **no Android SDK**, identical to the no-GPU/no-ComfyUI posture. Therefore:

- Tests cover `buildArtifactPlan`, the preset-cfg variants, and the new schema field; the spawn is **mocked**.
- `buildArtifact()` and the validator build-assertion **detect the SDK and skip cleanly when it is absent** (env/SDK probe or explicit `--with-android` opt-in).
- **`vitest` must stay green (currently 163/163).** Real builds only happen on this toolchain-equipped machine.

### 4. Packager skill + validator gate

- **`packager` SKILL.md:** add the build step after store-asset generation — call `package.mjs build`, record `store_pass.build_artifact`. Keep the existing "hand off to validator, do not auto-advance" posture.
- **validator SKILL.md (Method 5 extension or Method 6):** when the toolchain is present, assert the build artifact exists and is well-formed (file present, non-trivial size, ZIP/AAB signature; optionally `aapt dump badging`). When absent, **skip** (documented), so CI is unaffected.

### 5. Phase B — release path

- Generate a **release keystore** via `keytool`. Keystore file **and** its passwords are **git-ignored** and never committed; referenced via a local-only/env config.
- Build a **signed `.aab`** with `--export-release`.
- **Submission doc** under `docs/superpowers/specs/`: Play Console steps — developer account, app listing, content rating, internal-testing track, AAB upload. Submission itself is owner-gated.

### 6. Proof on creature-0001 & status ceremony

- Build debug APK → boot AVD → `adb install` → launch → **screenshot the running game**. Then build the signed AAB.
- **Build artifacts are git-ignored** (binaries are not source); record path/bytes/package/format in `store_pass.build_artifact`.
- **Status decision:** **prove the build and record `build_artifact`, but do NOT auto-advance creature-0001 to `packaged`.** The formal `packaged` gate requires the owner audio-A/B (`scored`) and the cross-modal cohesion check — those remain owner gates, consistent with how this repo handles human checkpoints. This milestone proves the *toolchain*, not the game's polish.

### 7. Testing

New offline `vitest` specs: `buildArtifactPlan` shape; APK-vs-AAB and debug-vs-release preset variants; schema accepts `build_artifact`; validator skips gracefully without the SDK. No network, no SDK, no GPU.

## Risks / open items

- **Godot headless Android export config:** CLI export reading editor settings is the most likely friction point; mitigated by the explicit editor-settings step and a probe before the real build.
- **AVD boot on this machine:** emulator may need a specific system-image/HAXV/Hyper-V; verify an image boots before relying on it.
- **`.gitignore` hygiene:** ensure `*.apk`, `*.aab`, `*.keystore`, and any signing-secret config are ignored before any build runs.

## Deliverables

1. `package.mjs` build seam (`buildArtifactPlan` + `buildArtifact` + preset variants) + CLI.
2. `store_pass.build_artifact` schema field.
3. `packager` skill build step + validator build-assertion (toolchain-guarded).
4. README "Android export" section + setup helper.
5. Phase B: release keystore (local, ignored) + signed AAB + Play submission doc.
6. Proof: creature-0001 debug APK running in the emulator (screenshot) + signed AAB; `build_artifact` recorded; status intentionally left `styled`.
7. `vitest` green (≥163, plus the new offline specs).
