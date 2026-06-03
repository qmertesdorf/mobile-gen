# deckbuilder-0001 — Shippable Raster Art Pass (design)

**Date:** 2026-06-02
**Status:** design (awaiting owner spec review)
**Supersedes:** the SVG asset pass on `deckbuilder-0001` (committed work in progress; `asset_pass.method="svg"`). This redo replaces the SVG enemies + background and the SVG card frames with painted raster art. It does **not** touch game logic — `CombatState`/`RunController`/`MetaSave`/`selftest.gd` are untouched; `SELFTEST OK` must still hold.

## 1. Why

The SVG pass made the game read as an *intentional toy* but not a shippable product (owner playtest, 2026-06-02: "rudimentary, fine for a POC demo, but there's no way this would ship — need real, high quality art"). Hand-authored vector cannot paint a creature, an illuminated card, or a real environment — exactly the boundary the `asset` skill flags, and exactly why the project built a local raster stack (ComfyUI + SDXL + LayerDiffuse). The 2026-06-02 owner directive already codified in `asset/SKILL.md` — *"raster is the default for art; do not retreat to SVG to dodge a quality problem"* — is precisely this situation. This pass takes the title from `playable` to a genuinely shippable `styled`.

**The deliverable is still a sharp re-skin *system*, not just a prettier game.** Every "this looks bad" must trace to a fixable cause — a weak prompt scaffold, a wrong style param, a mis-placed sprite, a legibility-scrim that didn't do its job, or an infra failure in `comfy.mjs` — never an unattributable blob. Findings get codified back into `asset/SKILL.md`.

## 2. Decisions (owner-confirmed)

- **Scope: full.** 4 painted enemies + 1 painted background + **16 painted card illustrations** (one per card in `CardDB`). Cards are ~90% of player attention, so per-card art is the single biggest quality jump.
- **Style: stylized modern arcane** — Hades / Inscryption-adjacent: bold clean shapes, strong rim lighting, controlled palette, modern indie polish; painterly but crisp. Not gritty-photoreal, not saturated-CCG.
- **Cards are full-bleed,** not framed-illustration. The painted art fills the whole card; chrome (border, scrims, badges, text) is drawn by **code** on top. This is the more premium, modern look (Marvel Snap / Inscryption), and it lets us **drop the SVG card frames entirely**.
- **Mixed-method, honestly recorded.** Raster: enemies, background, 16 card arts. Code/primitive (not SVG): all card chrome + all juice + all HUD. No SVG art ships in the final card pipeline (the SVG enemy/bg/frame files are removed or left unreferenced; recorded in `asset_pass`).

## 3. The three art categories

### 3.1 Card illustrations (16, opaque, full-bleed)

Each card's art is a single **iconic depiction of that spell** — the magical phenomenon as the focal subject, in the shared style, against an arcane-tinted backdrop that matches the element. **Opaque** rectangular illustration at card aspect (portrait 3:4) — uses the plain `sdxl` template (no LayerDiffuse; no alpha join needed). Generated at a master ~`768×1024` (3:4), drawn into the 120×160 card footprint (downscale-from-master, crisp on high-DPI).

Per-card subjects (subject phrase; the shared scaffold supplies style/lighting/palette):

| id | name | element | subject phrase |
|----|------|---------|----------------|
| arcane_bolt | Arcane Bolt | neutral | a bolt of raw violet arcane energy streaking forward |
| ward | Ward | neutral | a glowing protective arcane barrier rune, hexagonal shield of light |
| meditate | Meditate | neutral | a hooded mage's hands cupping a swirling orb of focused mana |
| mana_surge | Mana Surge | neutral | a burst of floating violet mana crystals and rising sparks |
| ember | Ember | fire | a single glowing ember bursting into a small flame |
| flame_lash | Flame Lash | fire | a whip of fire lashing through the air, trailing sparks |
| immolate | Immolate | fire | a towering conflagration, a roaring pillar of flame |
| wildfire | Wildfire | fire | spreading wildfire racing across scorched ground (a persistent power) |
| frost_shard | Frost Shard | ice | a sharp jagged shard of blue ice hurled forward |
| glacial_wall | Glacial Wall | ice | a towering wall of thick blue glacial ice |
| freeze | Freeze | ice | a figure encased in solid frozen ice, frost spreading |
| blizzard | Blizzard | ice | a swirling blizzard of snow and ice crystals |
| spark | Spark | lightning | a small crackling electric spark leaping between fingertips |
| chain_lightning | Chain Lightning | lightning | forked arcs of violet-white lightning chaining through the air |
| overload | Overload | lightning | a crackling overcharged sphere of unstable electricity (a persistent power) |
| thunderclap | Thunderclap | lightning | a violent burst of lightning and a shockwave of thunder |

### 3.2 Enemies (4, transparent RGBA)

Full-body painted creatures with native transparency (LayerDiffuse, `sdxl-layerdiffuse` template), in the shared style + the established world bible (one arcane-summon family). Replace the SVG silhouettes 1:1 at the same anchor. Masters ~`1024²`, drawn ~220px at the enemy anchor.

- **imp** — a small impish fire-demon, curved horns, bat wings, barbed tail, amber-glowing eyes, ember aura.
- **frost_wraith** — a tall floating hooded ice-wraith, tattered frost-rimed robe, cold cyan glow, no visible legs.
- **golem** — a broad hulking arcane stone golem, heavy shoulders, glowing violet energy core and cracks.
- **archmage** (boss) — a regal robed sorcerer, pointed hat, glowing rune-staff, commanding violet aura, imposing.

### 3.3 Background (1, opaque)

One painted **1280×720 arcane duelling chamber** (opaque, `sdxl` template, explicit `width:1280 height:768` → drawn full-frame): candle-lit stone hall ringed with glowing runes, a glowing floor runic circle where the enemy stands, depth and atmosphere. Drawn as the bottom layer. Replaces the SVG/primitive background.

## 4. Card chrome & legibility (the full-bleed risk, engineered away)

Full-bleed lives or dies on text legibility — our cards carry decision-critical gameplay text (1–3 effect lines + name + type + cost, read every turn). So legibility is **engineered in code**, never left to the art:

- **Bottom scrim** — a soft dark vertical gradient over the lower ~40% of the card (where effect text sits). Drawn over the art, under the text. Guarantees contrast regardless of the painting.
- **Top scrim** — a lighter dark gradient over the top ~22% for the card name.
- **Cost badge** — a solid filled circular badge top-left (element-tinted), cost number on it. Never floats over raw art.
- **Effect text** — drawn on the bottom scrim with a 1px drop-shadow/outline for belt-and-suspenders contrast.
- **Element border + pip** — a thin element-colored border around the card + a small element pip, so fire/ice/lightning is identifiable at a glance (gameplay-critical for the combo, not just decoration).
- **Affordability** — unaffordable cards keep the existing dim overlay; **selected** keeps the existing lift + bright rim.

Draw order per card: `art → bottom/top scrims → border → cost badge → name → type → effect text`.

**This is proven on card #1 in the probe (§6) before the batch** — if the text looks bad over a real generated illustration, we fall back to framed-illustration for cards (art window + opaque text panel) and keep enemies/bg raster. Cards are the only part with this fallback.

## 5. Style profile & shared scaffold (cohesion)

One profile, fixed across all 21 generations so the set reads as one designed thing (recorded verbatim in `asset_pass.visual_system`):

- **checkpoint:** `juggernautXL_v9.safetensors` (the proven SDXL finetune on this machine; base SDXL renders flat through LayerDiffuse).
- **style_prompt (shared):** `"stylized arcane fantasy game art, bold clean shapes, strong rim lighting, dramatic violet and amber arcane glow, controlled palette, modern indie polish, painterly but crisp"`.
- **scaffold (sprites):** `style_prompt + "single centered subject, full body, clean transparent background"` (+ per-actor subject).
- **scaffold (cards):** `style_prompt + "single iconic spell illustration, dramatic centered composition, arcane backdrop"` (+ per-card subject from §3.1). Cards are opaque (no transparent-background phrase).
- **negative (shared, all gens):** `"logo, watermark, text, letters, ui, frame, border, words, trademarked character, brand, celebrity likeness, multiple subjects, scene clutter, blurry, lowres"`. (`text/letters/words` matter especially for cards — the code draws the only text.)
- **params (fixed):** `sampler: euler`, `cfg: 7`, `steps: 24` (proven gate defaults). Per-actor `seed` recorded for provenance (not bit-exact reproducible — GPU nondeterminism).
- **import settings (mobile):** `mipmaps: true`, `filter: linear`, `compression: lossless` on each `.png.import`; high-res masters downscale to footprint.

## 6. Execution order (de-risked, probe-first)

- **Phase 0 — GPU probe + style lock.** Confirm `node tools/comfy.mjs --check` is reachable (owner boots `run_comfyui.bat`; free Ollama if resident — 16GB VRAM ceiling). Generate **1 enemy (imp) + 1 card (chain_lightning)** in the profile; for the card, composite the **real** scrim + cost badge + effect text over it and screenshot. **Owner judges by eye → lock or adjust the profile.** Gate: do not start the batch until the look (and card legibility) is approved.
- **Phase 1 — full batch** (profile locked): 4 enemies (RGBA), 1 background (opaque), 16 card arts (opaque). Headless `--import` after; set mobile `.png.import`.
- **Phase 2 — rewire `CombatView`.** Background → painted bottom layer. Enemies → painted sprites (flash/enrage/dissolve juice preserved via modulate/scale/alpha, unchanged). Cards → full-bleed art + code chrome/scrims/text (`_draw_card_face` rewritten; SVG frame draw removed). Remove the SVG art files + the now-dead SVG-frame code path.
- **Phase 3 — validate.** Headless import clean + headless run clean (no `SCRIPT ERROR`) + `SELFTEST OK` (rules untouched) + in-frame screenshot verification of all enemies + a combat hand + a reward screen on the RTX 5080. Record `asset_pass` (method `raster`, full `recipes[]`, mixed-method `left_primitive`). **Owner A/B** (looks shippable, reads as one world, plays identically, no IP-resemblance). On pass → `set-status styled`.

## 7. Files touched

- **Add:** `games/deckbuilder-0001/art/*.png` (+ `.png.import`) — 4 enemies, 1 bg, 16 card arts (21 PNGs).
- **Modify:** `games/deckbuilder-0001/CombatView.gd` (rewire bg/enemy/card draw to raster + full-bleed card chrome). `manifests/deckbuilder-0001.json` (`asset_pass` → raster, `assets[]` → png/raster origins).
- **Remove:** `games/deckbuilder-0001/art/*.svg` (+ sidecars) — the SVG enemies, background, and card frames are superseded.
- **Codify (only if the run surfaces a real gap):** `.claude/skills/asset/SKILL.md` — e.g. full-bleed card legibility-scrim guidance, opaque-card-art-via-sdxl-template note. Do not invent fixes for problems that didn't occur.

## 8. Validation / acceptance

- Headless import + 120-frame run: exit 0, no `SCRIPT ERROR` / `ERROR:` / "Failed to load".
- `godot --headless --script res://selftest.gd` → `SELFTEST OK` (game logic provably untouched).
- Manifest `validate` OK; `asset_pass.method = "raster"` with one recipe per PNG.
- Real-renderer screenshots confirm: all 4 enemies render in-frame; card text is legible over the painted art at 120×160; the background reads as a place; no double-draw / stale-halo artifacts.
- Owner A/B confirms shippable quality + cross-modal cohesion with `concept.theme` + no protected-IP resemblance (the IP safety gate before `styled`).

## 9. Out of scope

- Audio pass (Task 20 of the parent plan) — unchanged, follows after `styled`.
- Packaging → `packaged` (icons/atlas/splash/screenshots/APK) — owner-gated, downstream.
- New cards, enemies, relics, or mechanics — art only; `CardDB`/`EnemyDB`/rules frozen.
- Painted relic icons / title logo — kept out to stay tight to enemies + bg + cards (can be a later pass).

## 10. Risks & mitigations

- **Full-bleed text illegible over busy art** → engineered scrims (§4) + drop-shadow; **proven on card #1 in the probe** before the batch; framed-illustration fallback for cards only.
- **16 card arts drift in style** → one shared scaffold + fixed params + one checkpoint; the negative bans text/multi-subject; cohesion judged at the A/B as a *system* finding, not per-PNG.
- **A sprite fights the medium** (a tiny/effect-like subject comes back as a blob) → vary subject phrase → `master_resolution` → `cfg ±1`, 3–4 tries; if it still fights, that card falls back to a code/primitive treatment and is recorded (per the asset skill's mixed-method honesty).
- **ComfyUI unreachable / haze output** → infra failure, attributable to the stack (version pins/patches per the feasibility notes), never faked; stop and surface to owner.
- **GPU/VRAM** → 16GB ceiling; one generation at a time; free Ollama first.
- **Determinism** → committed PNG is canonical; `recipes[]` is provenance, not bit-exact regeneration.
