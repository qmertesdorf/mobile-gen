# Deckbuilder Raster Art Pass — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-skin `deckbuilder-0001` from rudimentary SVG to shippable painted raster art — full-bleed painted cards (16), transparent painted enemies (4), and one painted chamber background — taking the title `playable → styled`.

**Architecture:** Mixed-method re-skin. Raster art (ComfyUI + Juggernaut XL + LayerDiffuse via `tools/comfy.mjs`) for enemies, background, and the 16 card illustrations; **code-drawn chrome** (border, legibility scrims, cost badge, text) for cards instead of an authored frame. The `draw_texture*`-in-place strategy keeps the builder's single-`_draw()` renderer, preserving z-order + shake + all juice. **Game logic is frozen** — `CombatState`/`RunController`/`MetaSave`/`CardDB`/`EnemyDB` and `selftest.gd` are untouched, and `SELFTEST OK` is a hard gate after every code task. Probe-first: lock the style on 2 real generations before the 21-image batch.

**Tech Stack:** Godot 4.6.3.stable (GDScript, immediate-mode `_draw`), `tools/comfy.mjs` (local ComfyUI client), `tools/package.mjs screenshot` (real-renderer capture), `tools/manifest.mjs` (manifest seam). Windows / PowerShell host. GPU: RTX 5080 16GB.

**Spec:** `docs/superpowers/specs/2026-06-02-deckbuilder-raster-art-design.md` (committed `6c0fb2e`).

**Conventions used throughout:**
- Godot console exe (per `[[godot-binary-path]]`): `C:\Users\quint\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.6.3-stable_win64_console.exe` — referenced below as `<godot>`.
- `comfy.mjs gen <id> <name> '<recipe-json>'` writes `games/<id>/art/<name>.png`. Opaque images set `layerdiffuse:false` + explicit `width`/`height`; transparent sprites set `layerdiffuse:true` + `master_resolution`.
- Selftest gate (run after every code change): `<godot> --headless --path games/deckbuilder-0001/ --script res://selftest.gd` → must print `SELFTEST OK`, exit 0.
- Clean-run gate: `<godot> --headless --path games/deckbuilder-0001/ --quit-after 120` → no `SCRIPT ERROR` / `ERROR:` / "Failed to load".
- Screenshot helper: `node tools/package.mjs screenshot deckbuilder-0001 <name> <frames>` → writes `games/deckbuilder-0001/store/screenshots/<name>.png` on the real renderer; **Read** the PNG to judge; delete `games/deckbuilder-0001/store` before committing.

---

## Shared prompt material (use verbatim — this is what makes the 21 images cohere)

**STYLE (shared, every recipe's `prompt` starts with this):**
```
stylized arcane fantasy game art, bold clean shapes, strong rim lighting, dramatic violet and amber arcane glow, controlled palette, modern indie polish, painterly but crisp
```

**NEGATIVE (shared, every recipe):**
```
logo, watermark, text, letters, words, ui, frame, border, signature, trademarked character, brand, celebrity likeness, multiple subjects, scene clutter, photo, realistic photograph, blurry, lowres, deformed, extra limbs, ugly, mutated
```

**SPRITE scaffold** (enemies — transparent): `STYLE + ", single centered subject, full body, clean transparent background, " + <enemy subject>`
**CARD scaffold** (cards — opaque): `STYLE + ", single iconic spell illustration, dramatic centered composition, arcane backdrop, " + <card subject>`
**BG scaffold** (background — opaque): `STYLE + ", " + <bg subject>`

**Fixed params (every recipe):** `"sampler":"euler", "steps":24, "cfg":7`. Seeds are per-asset (recorded for provenance; not bit-exact reproducible).

---

## File structure

**Art (created):** `games/deckbuilder-0001/art/`
- `bg_chamber.png` (+ `.import`) — opaque painted background (replaces `bg_chamber.svg`).
- `enemy_imp.png`, `enemy_frost_wraith.png`, `enemy_golem.png`, `enemy_archmage.png` (+ `.import`) — transparent painted creatures (replace the `enemy_*.svg`).
- `card_<id>.png` (+ `.import`) ×16 — opaque painted card illustrations, one per `CardDB` id.

**Art (removed):** all 9 `games/deckbuilder-0001/art/*.svg` + their `.svg.import` sidecars (SVG enemies, background, and the 4 card frames — fully superseded).

**Code (modified):** `games/deckbuilder-0001/CombatView.gd` — swap texture maps to PNG; rewrite `_draw_card_face` for full-bleed + scrims; add scrim/shadow helpers. No other game file changes.

**Manifest (modified):** `manifests/deckbuilder-0001.json` — `asset_pass` (raster), `assets[]` (raster origins).

**Skill (modified, only on a real finding):** `.claude/skills/asset/SKILL.md`.

---

## Phase 0 — Probe & lock the style (owner-gated)

### Task 1: Generate the probe pair and lock the style profile

**Files:**
- Create (temporary, regenerated in Phase 1): `games/deckbuilder-0001/art/enemy_imp.png`, `games/deckbuilder-0001/art/card_chain_lightning.png`
- Create (temporary, throwaway): a probe screenshot

- [ ] **Step 1: Confirm ComfyUI is reachable**

Run: `node tools/comfy.mjs --check`
Expected: `comfy OK at http://127.0.0.1:8188 — N checkpoint(s): ...juggernautXL_v9.safetensors...`.
If `UNREACHABLE`: STOP and ask the owner to boot `C:\Users\quint\ComfyUI\run_comfyui.bat` (free Ollama first if resident: `Get-Process ollama* | Stop-Process -Force` — 16GB VRAM ceiling). This is infra, not an art problem — never fake a PNG.

- [ ] **Step 2: Generate the probe enemy (transparent imp)**

```
node tools/comfy.mjs gen deckbuilder-0001 enemy_imp "{\"checkpoint\":\"juggernautXL_v9.safetensors\",\"prompt\":\"stylized arcane fantasy game art, bold clean shapes, strong rim lighting, dramatic violet and amber arcane glow, controlled palette, modern indie polish, painterly but crisp, single centered subject, full body, clean transparent background, a small impish fire-demon with curved horns, bat wings, a barbed tail, glowing amber eyes, an ember aura\",\"negative\":\"logo, watermark, text, letters, words, ui, frame, border, signature, trademarked character, brand, celebrity likeness, multiple subjects, scene clutter, photo, realistic photograph, blurry, lowres, deformed, extra limbs, ugly, mutated\",\"seed\":201,\"sampler\":\"euler\",\"steps\":24,\"cfg\":7,\"master_resolution\":1024,\"layerdiffuse\":true,\"import_settings\":{\"mipmaps\":true,\"filter\":\"linear\",\"compression\":\"lossless\"}}"
```
Expected: `wrote games/deckbuilder-0001/art/enemy_imp.png`. On a graph/unreachable error it fails loudly — fix infra/recipe, do not fake.

- [ ] **Step 3: Generate the probe card art (opaque, 3:4)**

```
node tools/comfy.mjs gen deckbuilder-0001 card_chain_lightning "{\"checkpoint\":\"juggernautXL_v9.safetensors\",\"prompt\":\"stylized arcane fantasy game art, bold clean shapes, strong rim lighting, dramatic violet and amber arcane glow, controlled palette, modern indie polish, painterly but crisp, single iconic spell illustration, dramatic centered composition, arcane backdrop, forked arcs of violet-white lightning chaining through the air\",\"negative\":\"logo, watermark, text, letters, words, ui, frame, border, signature, trademarked character, brand, celebrity likeness, multiple subjects, scene clutter, photo, realistic photograph, blurry, lowres, deformed, extra limbs, ugly, mutated\",\"seed\":301,\"sampler\":\"euler\",\"steps\":24,\"cfg\":7,\"width\":768,\"height\":1024,\"layerdiffuse\":false,\"import_settings\":{\"mipmaps\":true,\"filter\":\"linear\",\"compression\":\"lossless\"}}"
```
Expected: `wrote games/deckbuilder-0001/art/card_chain_lightning.png`.

- [ ] **Step 4: Import + capture both on the real renderer**

```
<godot> --headless --path games/deckbuilder-0001/ --import
```
Then Read both PNGs directly (`games/deckbuilder-0001/art/enemy_imp.png`, `.../card_chain_lightning.png`) to eyeball raw quality.

- [ ] **Step 5: Build a throwaway card-legibility preview**

This proves the §4 scrim approach on a *real* illustration before committing to 16. Create `games/deckbuilder-0001/_probe.tscn` + `_probe.gd` (a `Node2D` that draws `card_chain_lightning.png` into a 120×160 rect, then the bottom scrim + top scrim + element border + cost badge + the real effect text "DMG 5" / "+6 vs afflicted" with drop-shadow — copy the helpers from Task 8). Capture with the screenshot helper at frame 30:
```
node tools/package.mjs screenshot deckbuilder-0001 probe-card 30
```
Read `games/deckbuilder-0001/store/screenshots/probe-card.png`.
(Delete `_probe.tscn`/`_probe.gd`/`store` after the owner decision.)

- [ ] **Step 6: OWNER GATE — judge and lock**

Present the imp sprite + the composited card preview to the owner. The owner confirms: (a) the style reads as "stylized modern arcane" and shippable; (b) the card text is legible over the painting. 
- **Approve** → the style profile + scrim approach are locked; proceed to Phase 1 unchanged.
- **Adjust style** → tweak the shared STYLE/params (e.g. cfg, a style descriptor), regenerate the pair, re-judge. Record what changed and why.
- **Card text illegible** → strengthen scrims (Task 8 fallback levers: taller/darker bottom scrim, opaque text panel) or fall back to framed-illustration cards (art window + opaque lower panel) — enemies/bg stay raster. Record the decision in the manifest notes.

Do **not** start Phase 1 until the owner approves. No commit in Phase 0 (the probe PNGs are overwritten in Phase 1; the `_probe.*` files are deleted).

---

## Phase 1 — Full batch generation

> Each `gen` writes one PNG. Run them one at a time (16GB VRAM ceiling — no concurrent large gens). If a single asset comes back weak, vary subject phrase → `master_resolution`/`width,height` → `cfg ±1` (3–4 tries); if it still fights the medium, record it for a code/primitive fallback (asset-skill mixed-method honesty) rather than shipping a blob.

### Task 2: Generate the 4 enemy sprites (transparent)

**Files:**
- Create: `games/deckbuilder-0001/art/enemy_{imp,frost_wraith,golem,archmage}.png`

- [ ] **Step 1: Generate imp** — already produced in Task 1 Step 2 (seed 201). Keep it. If Phase 0 adjusted the style, regenerate with the locked profile.

- [ ] **Step 2: Generate frost_wraith**

```
node tools/comfy.mjs gen deckbuilder-0001 enemy_frost_wraith "{\"checkpoint\":\"juggernautXL_v9.safetensors\",\"prompt\":\"stylized arcane fantasy game art, bold clean shapes, strong rim lighting, dramatic violet and amber arcane glow, controlled palette, modern indie polish, painterly but crisp, single centered subject, full body, clean transparent background, a tall floating hooded ice-wraith in a tattered frost-rimed robe, cold cyan inner glow, no visible legs, ghostly\",\"negative\":\"logo, watermark, text, letters, words, ui, frame, border, signature, trademarked character, brand, celebrity likeness, multiple subjects, scene clutter, photo, realistic photograph, blurry, lowres, deformed, extra limbs, ugly, mutated\",\"seed\":202,\"sampler\":\"euler\",\"steps\":24,\"cfg\":7,\"master_resolution\":1024,\"layerdiffuse\":true,\"import_settings\":{\"mipmaps\":true,\"filter\":\"linear\",\"compression\":\"lossless\"}}"
```
Expected: `wrote ...art/enemy_frost_wraith.png`.

- [ ] **Step 3: Generate golem**

```
node tools/comfy.mjs gen deckbuilder-0001 enemy_golem "{\"checkpoint\":\"juggernautXL_v9.safetensors\",\"prompt\":\"stylized arcane fantasy game art, bold clean shapes, strong rim lighting, dramatic violet and amber arcane glow, controlled palette, modern indie polish, painterly but crisp, single centered subject, full body, clean transparent background, a broad hulking arcane stone golem with heavy shoulders, a glowing violet energy core and glowing cracks\",\"negative\":\"logo, watermark, text, letters, words, ui, frame, border, signature, trademarked character, brand, celebrity likeness, multiple subjects, scene clutter, photo, realistic photograph, blurry, lowres, deformed, extra limbs, ugly, mutated\",\"seed\":203,\"sampler\":\"euler\",\"steps\":24,\"cfg\":7,\"master_resolution\":1024,\"layerdiffuse\":true,\"import_settings\":{\"mipmaps\":true,\"filter\":\"linear\",\"compression\":\"lossless\"}}"
```
Expected: `wrote ...art/enemy_golem.png`.

- [ ] **Step 4: Generate archmage (boss)**

```
node tools/comfy.mjs gen deckbuilder-0001 enemy_archmage "{\"checkpoint\":\"juggernautXL_v9.safetensors\",\"prompt\":\"stylized arcane fantasy game art, bold clean shapes, strong rim lighting, dramatic violet and amber arcane glow, controlled palette, modern indie polish, painterly but crisp, single centered subject, full body, clean transparent background, a regal robed archmage sorcerer with a pointed hat, a glowing rune-staff, commanding violet aura, imposing\",\"negative\":\"logo, watermark, text, letters, words, ui, frame, border, signature, trademarked character, brand, celebrity likeness, multiple subjects, scene clutter, photo, realistic photograph, blurry, lowres, deformed, extra limbs, ugly, mutated\",\"seed\":204,\"sampler\":\"euler\",\"steps\":24,\"cfg\":7,\"master_resolution\":1024,\"layerdiffuse\":true,\"import_settings\":{\"mipmaps\":true,\"filter\":\"linear\",\"compression\":\"lossless\"}}"
```
Expected: `wrote ...art/enemy_archmage.png`.

- [ ] **Step 5: Eyeball each** — Read all 4 PNGs. Confirm clean transparency (no haze/gray-interior — that would be a stack-version issue, not the recipe), distinct silhouettes, one coherent family. Regenerate any weak one with a varied subject phrase before moving on.

(No commit yet — commit the whole art batch after Task 5's import settings.)

### Task 3: Generate the chamber background (opaque)

**Files:**
- Create: `games/deckbuilder-0001/art/bg_chamber.png`

- [ ] **Step 1: Generate the background** (opaque, landscape ~16:9)

```
node tools/comfy.mjs gen deckbuilder-0001 bg_chamber "{\"checkpoint\":\"juggernautXL_v9.safetensors\",\"prompt\":\"stylized arcane fantasy game art, bold clean shapes, strong rim lighting, dramatic violet and amber arcane glow, controlled palette, modern indie polish, painterly but crisp, a candle-lit stone arcane duelling chamber ringed with glowing runes, a glowing runic circle on the floor, atmospheric depth, empty center stage, no characters\",\"negative\":\"logo, watermark, text, letters, words, ui, frame, border, signature, trademarked character, brand, celebrity likeness, characters, creatures, people, blurry, lowres\",\"seed\":401,\"sampler\":\"euler\",\"steps\":24,\"cfg\":7,\"width\":1280,\"height\":768,\"layerdiffuse\":false,\"import_settings\":{\"mipmaps\":true,\"filter\":\"linear\",\"compression\":\"lossless\"}}"
```
Expected: `wrote ...art/bg_chamber.png`. Note: generated 1280×768, drawn into 1280×720 (slight vertical crop/squash — acceptable for an atmospheric backdrop). Add `"characters, creatures, people"` to the negative so the stage stays empty for the sprite enemies.

- [ ] **Step 2: Eyeball** — Read `bg_chamber.png`. Confirm it reads as a place (depth, runes, floor circle), center stage uncluttered so the enemy sprite sits cleanly. Regenerate if busy/flat.

### Task 4: Generate the 16 card illustrations (opaque)

**Files:**
- Create: `games/deckbuilder-0001/art/card_<id>.png` ×16

- [ ] **Step 1: Generate all 16** — one `gen` per card, opaque 3:4 (`width:768, height:1024`), `card_<id>` as the asset name, subject from the table. `chain_lightning` exists from Task 1 (keep or regen under locked profile). Use seeds 301–316. Template for each (substitute `<id>`, `<subject>`, `<seed>`):

```
node tools/comfy.mjs gen deckbuilder-0001 card_<id> "{\"checkpoint\":\"juggernautXL_v9.safetensors\",\"prompt\":\"stylized arcane fantasy game art, bold clean shapes, strong rim lighting, dramatic violet and amber arcane glow, controlled palette, modern indie polish, painterly but crisp, single iconic spell illustration, dramatic centered composition, arcane backdrop, <subject>\",\"negative\":\"logo, watermark, text, letters, words, ui, frame, border, signature, trademarked character, brand, celebrity likeness, multiple subjects, scene clutter, photo, realistic photograph, blurry, lowres, deformed, extra limbs, ugly, mutated\",\"seed\":<seed>,\"sampler\":\"euler\",\"steps\":24,\"cfg\":7,\"width\":768,\"height\":1024,\"layerdiffuse\":false,\"import_settings\":{\"mipmaps\":true,\"filter\":\"linear\",\"compression\":\"lossless\"}}"
```

| id | seed | subject |
|----|------|---------|
| arcane_bolt | 301 | a bolt of raw violet arcane energy streaking forward |
| ward | 302 | a glowing protective arcane barrier rune, hexagonal shield of light |
| meditate | 303 | a hooded mage's hands cupping a swirling orb of focused mana |
| mana_surge | 304 | a burst of floating violet mana crystals and rising sparks |
| ember | 305 | a single glowing ember bursting into a small flame |
| flame_lash | 306 | a whip of fire lashing through the air, trailing sparks |
| immolate | 307 | a towering conflagration, a roaring pillar of flame |
| wildfire | 308 | spreading wildfire racing across scorched ground |
| frost_shard | 309 | a sharp jagged shard of blue ice hurled forward |
| glacial_wall | 310 | a towering wall of thick blue glacial ice |
| freeze | 311 | a lone figure encased in solid frozen blue ice, frost spreading |
| blizzard | 312 | a swirling blizzard of snow and ice crystals |
| spark | 313 | a small crackling electric spark leaping between fingertips |
| chain_lightning | 314 | forked arcs of violet-white lightning chaining through the air |
| overload | 315 | a crackling overcharged sphere of unstable electricity |
| thunderclap | 316 | a violent burst of lightning and a shockwave of thunder |

Expected each: `wrote ...art/card_<id>.png`.

- [ ] **Step 2: Eyeball the set** — Read a representative sample (one per element + any that risk reading as a "scene"). Confirm cohesion (one style) and that each is a single clear subject (the negative bans multi-subject/scene clutter). Regenerate any outlier. Tiny/effect-like subjects (e.g. `spark`) that come back as blobs: vary phrase/res/cfg 3–4×, else note for a code fallback in the rewire (the element border + name still identify the card).

### Task 5: Set mobile import settings + import pass

**Files:**
- Modify: `games/deckbuilder-0001/art/*.png.import` (21 files)

- [ ] **Step 1: Run the import pass** to create `.png.import` sidecars + cached textures

```
<godot> --headless --path games/deckbuilder-0001/ --import
```
Expected: 21 `*.png.import` sidecars exist under `games/deckbuilder-0001/art/`.

- [ ] **Step 2: Confirm mobile-grade import settings** — `comfy.mjs` records `import_settings` but the sidecar is written by Godot; verify each `.png.import` has `mipmaps/generate=true` and a lossless/linear setup (the small fixed asset count → lossless is fine). If Godot wrote defaults, set `mipmaps/generate=true` in each sidecar and re-run the import pass. (Card/bg are opaque, enemies are RGBA — all 2D.)

- [ ] **Step 3: Commit the art batch**

```bash
git add games/deckbuilder-0001/art/*.png games/deckbuilder-0001/art/*.png.import
git commit -m "feat(asset): generate painted raster art — 4 enemies, chamber bg, 16 card illustrations (Juggernaut XL)"
```

---

## Phase 2 — Rewire CombatView to the raster art

> All edits are in `games/deckbuilder-0001/CombatView.gd`. The selftest + clean-run gates run after every task — rules must stay untouched. Tab-indented GDScript: if an `Edit` exact-match fails on tab/space, use the PowerShell line-splice fallback (Get-Content → reconstruct → Set-Content) from `asset/SKILL.md`.

### Task 6: Point the texture maps at PNG + add the card-art map

**Files:**
- Modify: `games/deckbuilder-0001/CombatView.gd` (the `_ready()` loader + member vars)

- [ ] **Step 1: Replace the SVG load paths with PNG, add `_tex_cardart`**

In `_ready()`, change the `_tex_bg` / `_tex_card` / `_tex_enemy` loads from `res://art/*.svg` to the new PNG names, and add a per-card-id art map. Replace the asset-load block with:

```gdscript
	# ── Asset pass (raster): load painted PNG art. Guarded null-fallback per draw helper.
	_tex_bg = _try_load("res://art/bg_chamber.png")
	_tex_enemy = {
		"imp":          _try_load("res://art/enemy_imp.png"),
		"frost_wraith": _try_load("res://art/enemy_frost_wraith.png"),
		"golem":        _try_load("res://art/enemy_golem.png"),
		"archmage":     _try_load("res://art/enemy_archmage.png"),
	}
	# Full-bleed card illustrations, keyed by CardDB id.
	_tex_cardart = {}
	for cid in CardDB.all_ids():
		_tex_cardart[cid] = _try_load("res://art/card_%s.png" % cid)
```

- [ ] **Step 2: Update member vars** — replace the `_tex_card` declaration with `_tex_cardart`:

```gdscript
var _tex_bg: Texture2D = null
var _tex_cardart: Dictionary = {}   # card id -> Texture2D (full-bleed art)
var _tex_enemy: Dictionary = {}     # enemy id -> Texture2D
```

- [ ] **Step 3: Gates** — selftest `SELFTEST OK` + clean run. (Cards/bg will still render via fallback or new art; the `_draw_card_face` rewrite is Task 8.) The background + enemy draws already reference `_tex_bg`/`_tex_enemy` and now get PNGs.

- [ ] **Step 4: Commit**

```bash
git add games/deckbuilder-0001/CombatView.gd
git commit -m "feat(asset): load painted PNG art (bg, enemies, per-card illustrations)"
```

### Task 7: Confirm enemy + background draws render the PNGs

**Files:**
- Modify (only if needed): `games/deckbuilder-0001/CombatView.gd` (`_draw_enemy` sizing)

The existing `_draw_background()` (full-frame `draw_texture_rect(_tex_bg, ...)`) and `_draw_enemy()` (textured draw with flash/enrage/dissolve) already work for PNGs unchanged. This task verifies and tunes sizing only.

- [ ] **Step 1: Screenshot the opening combat**

```
node tools/package.mjs screenshot deckbuilder-0001 verify-combat 140
```
Read `games/deckbuilder-0001/store/screenshots/verify-combat.png`. Confirm: painted background fills the frame; the imp **sprite** sits on the stage at a good size (occupies a prominent share, clearly the focal subject — bump the `220.0` base size in `_draw_enemy` if the painted creature reads small against the richer bg, per the spec's "size the hero for the frame").

- [ ] **Step 2: If resized, re-gate** — selftest `SELFTEST OK` + clean run.

- [ ] **Step 3: Commit (if changed)**

```bash
git add games/deckbuilder-0001/CombatView.gd
git commit -m "feat(asset): size enemy sprite for the painted frame"
```

### Task 8: Rewrite `_draw_card_face` for full-bleed art + code chrome

**Files:**
- Modify: `games/deckbuilder-0001/CombatView.gd` (`_draw_card_face` + new helpers)

This is the core of the pass. Replace the whole `_draw_card_face` body with: full-bleed art → bottom/top legibility scrims → element border → cost badge → name → type → effect lines (drop-shadowed). Add two helpers.

- [ ] **Step 1: Add the scrim + shadowed-text helpers** (after `_draw_text_alpha`)

```gdscript
# Vertical-gradient scrim via a per-vertex-coloured quad (immediate-mode gradient).
func _draw_vscrim(r: Rect2, c_top: Color, c_bot: Color) -> void:
	var pts := PackedVector2Array([
		r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)
	])
	var cols := PackedColorArray([c_top, c_top, c_bot, c_bot])
	draw_polygon(pts, cols)

# Text with a 1px drop-shadow for contrast over painted art.
func _draw_text_shadow(pos: Vector2, text: String, size: int, col: Color, centered: bool = false) -> void:
	_draw_text(pos + Vector2(1.0, 1.0), text, size, Color(0.0, 0.0, 0.0, 0.85), centered)
	_draw_text(pos, text, size, col, centered)
```

- [ ] **Step 2: Replace `_draw_card_face`** with the full-bleed implementation:

```gdscript
func _draw_card_face(rect: Rect2, card_data: Dictionary, affordable: bool, selected: bool) -> void:
	var elem: String = card_data.get("element", "neutral")
	var elem_col: Color = _element_color(elem)
	var cost: int = card_data.get("cost", 0)
	var c_name: String = card_data.get("name", "???")
	var c_type: String = card_data.get("type", "")
	var effect: Dictionary = card_data.get("effect", {})
	var card_id: String = card_data.get("id", "")

	# Selected glow halo (behind the card).
	if selected:
		draw_rect(Rect2(rect.position - Vector2(6, 6), rect.size + Vector2(12, 12)),
			Color(COL_SELECTED.r, COL_SELECTED.g, COL_SELECTED.b, 0.35))

	# 1. Full-bleed painted art (fallback: dark card body).
	var art: Texture2D = _tex_cardart.get(card_id, null)
	if art != null:
		draw_texture_rect(art, rect, false)
	else:
		draw_rect(rect, COL_CARD_BG)

	# 2. Legibility scrims — bottom (effect text) + top (name).
	var bottom_h: float = rect.size.y * 0.42
	_draw_vscrim(Rect2(rect.position.x, rect.end.y - bottom_h, rect.size.x, bottom_h),
		Color(0.04, 0.03, 0.09, 0.0), Color(0.04, 0.03, 0.09, 0.88))
	var top_h: float = rect.size.y * 0.22
	_draw_vscrim(Rect2(rect.position.x, rect.position.y, rect.size.x, top_h),
		Color(0.04, 0.03, 0.09, 0.78), Color(0.04, 0.03, 0.09, 0.0))

	# 3. Element border (gameplay-critical: identifies fire/ice/lightning at a glance).
	var border_col: Color = elem_col if affordable else Color(0.35, 0.35, 0.4, 0.8)
	if selected:
		border_col = COL_SELECTED
	draw_rect(rect, border_col, false, 2.0)

	# 4. Cost badge (solid, top-left — never floats over raw art).
	var badge_c := Vector2(rect.position.x + 14.0, rect.position.y + 15.0)
	draw_circle(badge_c, 11.0, Color(0.06, 0.05, 0.12, 0.95))
	draw_arc(badge_c, 11.0, 0.0, TAU, 20, elem_col if affordable else Color(0.4, 0.4, 0.45), 2.0)
	_draw_text_shadow(badge_c + Vector2(0.0, 4.0), str(cost), 13, COL_WHITE, true)

	# 5. Name (top, on the top scrim).
	_draw_text_shadow(Vector2(rect.get_center().x, rect.position.y + 18.0), c_name, 11, COL_WHITE, true)

	# 6. Element pip + type tag (just above the effect block).
	var type_y: float = rect.end.y - bottom_h + 10.0
	draw_circle(Vector2(rect.position.x + 12.0, type_y - 4.0), 4.0, elem_col)
	_draw_text_shadow(Vector2(rect.get_center().x, type_y), c_type.to_upper(), 9, elem_col, true)

	# 7. Effect lines (bottom, on the bottom scrim, drop-shadowed).
	var eff_lines: Array = _effect_summary(effect, elem)
	var ey: float = type_y + 18.0
	for line in eff_lines:
		_draw_text_shadow(Vector2(rect.get_center().x, ey), line, 10, COL_WHITE, true)
		ey += 14.0

	# 8. Unaffordable dim overlay.
	if not affordable:
		draw_rect(rect, Color(0.0, 0.0, 0.0, 0.45))
```

- [ ] **Step 3: Gates** — selftest `SELFTEST OK` + clean run (no `SCRIPT ERROR`).

- [ ] **Step 4: Screenshot the hand + a reward screen**

```
node tools/package.mjs screenshot deckbuilder-0001 verify-cards 140
```
Read `games/deckbuilder-0001/store/screenshots/verify-cards.png`. Confirm: every card's cost, name, type, and effect lines are **legible** over the painting; element border reads; selected/unaffordable states still work. If any text is hard to read, deepen the bottom scrim (`0.88 → 0.94`, `0.42 → 0.48`) — these are the tuning levers. This is the spec's full-bleed risk being closed on real art.

- [ ] **Step 5: Commit**

```bash
git add games/deckbuilder-0001/CombatView.gd
git commit -m "feat(asset): full-bleed painted cards — art + legibility scrims + cost badge + shadowed text"
```

### Task 9: Remove the superseded SVG art + dead code

**Files:**
- Delete: `games/deckbuilder-0001/art/*.svg` + `*.svg.import`
- Modify: `games/deckbuilder-0001/CombatView.gd` (drop the now-dead SVG-frame fallback rects in `_draw_card_face` already gone; remove `_motes` only if unused)

- [ ] **Step 1: Delete the SVG files**

```powershell
Remove-Item games/deckbuilder-0001/art/*.svg, games/deckbuilder-0001/art/*.svg.import
```

- [ ] **Step 2: Confirm nothing references the SVGs** — Grep `CombatView.gd` for `.svg`; expect no matches. The `_draw_background`/`_draw_enemy` primitive fallbacks (gradient/polygon) may stay as harmless null-guards, or be removed for tidiness — leaving them is fine (they only fire if a PNG is missing). Do not remove the `_motes` generator unless `_draw_background`'s primitive fallback that uses it is also removed.

- [ ] **Step 3: Gates** — selftest `SELFTEST OK` + clean run + one more screenshot (`verify-final 140`) to confirm removal didn't disturb rendering. Delete `store` after reading.

- [ ] **Step 4: Commit**

```bash
git add -A games/deckbuilder-0001/art/
git commit -m "chore(asset): remove superseded SVG art (enemies, bg, card frames)"
```

---

## Phase 3 — Validate, record, advance

### Task 10: Validator re-skin re-validation (Method 3)

**Files:** none (verification only)

- [ ] **Step 1: Import + clean run**

```
<godot> --headless --path games/deckbuilder-0001/ --import
<godot> --headless --path games/deckbuilder-0001/ --quit-after 120
```
Expected: exit 0, no `SCRIPT ERROR` / `ERROR:` / "Failed to load".

- [ ] **Step 2: Selftest (logic frozen)**

```
<godot> --headless --path games/deckbuilder-0001/ --script res://selftest.gd
```
Expected: `SELFTEST OK`, exit 0.

- [ ] **Step 3: In-frame screenshot sweep** — capture the opening combat + temporarily swap the first run node (`RunController.gd` line 28) to `frost_wraith`/`golem`/`archmage` to screenshot each enemy on the painted stage (revert after, re-run selftest). Read each; confirm all 4 painted enemies render in-frame, no double-draw / stale-halo artifacts. Delete `store` after.

### Task 11: Record the `asset_pass` (raster) + flip `assets[]`

**Files:**
- Modify: `manifests/deckbuilder-0001.json` (via `tools/manifest.mjs`)

- [ ] **Step 1: Flip `assets[]`** to the raster sources (full array; one per PNG):

```
node tools/manifest.mjs merge deckbuilder-0001 "{\"assets\": [ {\"type\":\"background\",\"name\":\"chamber\",\"source\":\"art/bg_chamber.png\",\"origin\":\"raster\"}, {\"type\":\"sprite\",\"name\":\"enemy_imp\",\"source\":\"art/enemy_imp.png\",\"origin\":\"raster\"}, {\"type\":\"sprite\",\"name\":\"enemy_frost_wraith\",\"source\":\"art/enemy_frost_wraith.png\",\"origin\":\"raster\"}, {\"type\":\"sprite\",\"name\":\"enemy_golem\",\"source\":\"art/enemy_golem.png\",\"origin\":\"raster\"}, {\"type\":\"sprite\",\"name\":\"enemy_archmage\",\"source\":\"art/enemy_archmage.png\",\"origin\":\"raster\"}, {\"type\":\"sprite\",\"name\":\"card_art\",\"source\":\"art/card_*.png\",\"origin\":\"raster\"} ]}"
```

- [ ] **Step 2: Write the `asset_pass`** (method raster; full `recipes[]` — one per generated PNG with checkpoint/prompt/negative/seed/sampler/steps/cfg/dims/layerdiffuse/import_settings; copy from the recipes used in Phase 1). Record `visual_system` (world_bible, palette, style profile, prompt_scaffold), `reskinned` (enemies, bg, 16 card arts), `left_primitive` (all card chrome + scrims + HUD + juice — code, not art), `method:"raster"`, `notes` (full-bleed cards via code scrims; opaque card art via `sdxl` template; draw_texture*-in-place; any per-asset fallbacks). Use the `merge` form from `asset/SKILL.md`'s raster recording block.

- [ ] **Step 3: Validate**

```
node tools/manifest.mjs validate deckbuilder-0001
```
Expected: `deckbuilder-0001 OK` (still `playable`).

- [ ] **Step 4: Commit**

```bash
git add manifests/deckbuilder-0001.json
git commit -m "feat(asset): record raster asset_pass (full-bleed cards + painted enemies + bg)"
```

### Task 12: Owner A/B → `styled`

**Files:**
- Modify: `manifests/deckbuilder-0001.json`

- [ ] **Step 1: Owner A/B** — owner plays a run (or judges the screenshot sweep): does it look **shippable**, read as one coherent arcane world, play identically, and show no protected-IP resemblance (the IP-safety gate)? Launch: `Start-Process "<godot>" -ArgumentList '--path','games/deckbuilder-0001/'`.

- [ ] **Step 2: On approval, advance**

```
node tools/manifest.mjs set-status deckbuilder-0001 styled
node tools/manifest.mjs validate deckbuilder-0001
```
Expected: `status = "styled"`. If rejected, record the specific issue in `asset_pass.notes`, attribute it to `asset`, and iterate — do not advance.

- [ ] **Step 3: Commit**

```bash
git add manifests/deckbuilder-0001.json
git commit -m "feat(asset): owner A/B confirmed shippable — status styled"
```

### Task 13: Codify findings into `asset/SKILL.md` (only real gaps)

**Files:**
- Modify: `.claude/skills/asset/SKILL.md` (only if the run surfaced a concrete gap)

- [ ] **Step 1: Fold in what the build actually surfaced** — likely candidates: the **full-bleed card pattern** (opaque card art via the `sdxl` template + code-drawn legibility scrims via a per-vertex-coloured quad + drop-shadowed text + element border for at-a-glance identity), and the probe-card legibility-proof step. Do **not** invent fixes for problems that didn't occur — only codify real findings (asset-skill discipline).

- [ ] **Step 2: Commit**

```bash
git add .claude/skills/asset/SKILL.md
git commit -m "docs(asset): codify full-bleed raster card pattern + legibility scrims from deckbuilder run"
```

---

## Out of scope (this plan)
- Audio pass (parent plan Task 20) — after `styled`.
- Packaging → `packaged` (icons/atlas/splash/screenshots/APK) — owner-gated, downstream.
- New cards/enemies/relics/mechanics — art only; `CardDB`/`EnemyDB`/rules frozen.
- Painted relic icons / title logo — a possible later pass.

## Self-review notes (writing-plans checklist)
- **Spec coverage:** §2 decisions → Tasks 1 (style lock), 2–4 (full scope), 8 (full-bleed). §3.1 card arts → Task 4 (+subjects table). §3.2 enemies → Task 2. §3.3 bg → Task 3. §4 legibility scrims → Task 8 (+ Task 1 probe proof). §5 style profile/scaffold/negative/params → Shared-material section + every recipe. §6 execution order → Phases 0–3. §7 files → File-structure section + Tasks 5/6/9/11. §8 validation → Tasks 10/12. §9 out-of-scope → mirrored. §10 risks → Task 1 gate (legibility/infra), Task 2/4 Step "eyeball"/fallback (fights-the-medium), Task 5 (mobile import).
- **Placeholder scan:** every recipe + GDScript block is complete and literal; no TBD/TODO.
- **Type/name consistency:** `_tex_bg`/`_tex_enemy`/`_tex_cardart` (Task 6) used identically in Tasks 7/8; `card_<id>.png` naming used in Task 4 (write), Task 6 (load), Task 9 (keep); `_draw_vscrim`/`_draw_text_shadow` defined in Task 8 Step 1 and used in Step 2; enemy ids match `EnemyDB` (`imp`/`frost_wraith`/`golem`/`archmage`); `CardDB.all_ids()` drives the card-art map.
- **Frozen logic:** no task edits `CombatState`/`RunController`/`MetaSave`/`CardDB`/`EnemyDB`/`selftest.gd`; `SELFTEST OK` gate after every code task (6,7,8,9) + Task 10.
