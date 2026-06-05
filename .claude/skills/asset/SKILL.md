---
name: asset
description: Use when re-skinning a playable Godot game with coherent, Claude-authored art. Branches on concept.art_direction — raster (representational/illustrated, the default for character/creature/scene art: RGBA PNGs via local ComfyUI+SDXL+LayerDiffuse through tools/comfy.mjs) or svg (geometric/UI/flat, authored inline as text). Derives a visual system, rewires primitive _draw() to textures, records asset_pass, and hands off to the visual-audit skill (which judges the composited running game) ahead of validator's "styled" gate.
---

# asset

Replace a `playable` game's deliberate **primitive** visuals with real, coherent, **Claude-authored art**, so the title goes from "intentional toy" to "looks designed" — recorded legibly in the manifest. The deliverable is a sharp re-skin **system**, not one prettier game: every gap must trace to specific prose here. Runs as a clean bolt-on after `playable`:

```
concept → builder → validator → [playable] → asset → visual-audit → validator(re-run) → [styled]
```

## Choosing the method (branch on `concept.art_direction`)

First **read `concept.theme`** — the title's modality-neutral world (premise/tone/mood/setting). `art_direction` is the *visual expression* of that theme: the system you derive must read as *that world*, the same one the audio and store icon express — not a free-standing aesthetic. (Reading the theme is not editing it; the "consume `concept` as-is" rule holds.)

Two methods, both sharing all the rewiring craft below — only how the texture is *produced* differs:

- **representational / character / creature / illustrated / textured → `raster`** (the default for art): RGBA PNGs generated via local ComfyUI + SDXL + LayerDiffuse. This is what SVG does badly — a painted hero, a creature, a textured scene.
- **geometric / neon / flat / hyper-casual / pure UI → `svg`**: authored inline as text, rasterized by Godot's importer. Resolution-independent — one file covers every Android density bucket.

**Raster is the default; do not retreat to SVG to dodge a quality problem.** The remedy for "terrible" raster is to *lift raster quality* (better backgrounds, sizing, the levers below), not to fall back to vectors. Choose `svg` only for a genuine reason — a UI/HUD/geometric element where vector resolution-independence is a real win — and state that justification in `asset_pass.notes`. A run may be **mixed-method** (some entities `raster`, some `svg`, some left `primitive`); see "Mixed-method honesty".

**But UI CHROME is NOT a quality-dodge — it is the canonical `svg`/code case; do NOT raster-generate frames/panels/buttons/bars.** "Don't retreat to SVG" applies to *representational art* (a hero that came back weak → fix the raster, don't vectorize it). It does **not** license throwing SDXL+LayerDiffuse at wide, variable-size UI chrome — an ornate panel/button frame, a 9-slice border, a HP-bar gauge, a HUD plate. Those need **symmetry, clean tileable/9-slice edges, and exact aspect control**, and diffusion delivers none on demand: a generated frame's four corners never match, it adds mid-edge ornaments + alpha fringe, and stretching a square token to a wide/short target distorts it. Proven the hard way: a painted 9-slice gold frame (generated plaque → alpha-extracted → nine-patched over code fills) read as lumpy/asymmetric/stuck-on in live play and was owner-rejected; the clean styled-code chrome it replaced "sat nicely." So for UI chrome the correct tool is **`svg` (author the frame as vector — you control symmetry + margins, it 9-slices perfectly, scales to every density) or clean styled CODE** (gradient + bevel + corner accents reads as designed). Reserve raster generation for **centered-subject art** (cards, enemies, small element glyphs) — the model's actual strength. The visual-audit fidelity lens calling code chrome "programmer-art" does **not** mean force-generate a raster frame; clean vector/code chrome is the *right* answer there, and the owner's eye on the composited screen is the arbiter. A hybrid (generate only the ornate *corner pieces* as centered subjects + code/vector edges) is the middle path if you want a painted touch without the lumpy full-frame.

## Inputs
- `manifests/<id>.json` with a populated `concept` block and `status = "playable"`.
- The generated project at `games/<id>/` (typically a single `Node2D` whose `Main.gd` draws every entity procedurally in `_draw()`).
- The pinned Godot version from `README.md`.

## Outputs
- `games/<id>/art/*` — one Claude-authored texture per re-skinned entity (`.png` raster / `.svg` vector).
- A rewired `Main.gd` / `Main.tscn` displaying them via `draw_texture*` / `Sprite2D` / `TextureRect`.
- A populated `asset_pass` block and flipped `assets[]` entries (`origin:"raster"|"svg"`).
- `status = "styled"` (after the validator re-run passes).

## Hard requirements
- The re-skinned project MUST still import and run **headless with no script errors** (validator re-enforces).
- Game **logic is untouched** — movement, collision, spawning, scoring, input, game-over/restart behave exactly as before. Only the *visual representation* changes. If a `selftest.gd` exists it must still print `SELFTEST OK`.
- **No double-draw:** for every re-skinned entity the old `_draw()` primitive is removed or guarded. Leaving the primitive *and* adding the texture is the most common failure — prevent it.
- No new MCP tool or dependency beyond the existing `tools/comfy.mjs` raster stack.
- Do **not** edit `concept` or `builder`. Consume `concept.art_direction` as-is.

## Step 0 — Derive the visual system FIRST (the real deliverable)

A real asset creator produces **one coherent visual system** applied everywhere, not a pile of independently-acceptable shapes. "Each asset is fine but they don't cohere" is the **primary failure** this step prevents; when it happens it's attributable to *this system*, not the individual files. Before authoring/generating anything, write it down from `concept.art_direction`:

- **World/character bible (derive FIRST)** — from `theme.setting` + `premise`, pin **one fictional world and one character family** before any subject is chosen. Every actor — hero, hazard, pickup — is an inhabitant of that one world (same materials, era/genre, "what kind of thing is this"). The hero and hazard must read as belonging together — *not a cyan robot vs. a red ogre*. This is the *subject-level* sibling of palette/form/shading below (which pin only *how* things render, never *what world they're from*). Recorded in `asset_pass.visual_system.world_bible`. Applies to **both** methods.
- **Palette** — a fixed 3–5 colour set with named roles (primary, accent, danger, background). Every fill/stroke comes from it.
- **Line/stroke** — one weight, one join/cap, throughout.
- **Form language** — corner radius, geometric vs. organic, detail level. Pick one and hold it. Then give **each** actor *one* signature silhouette detail (a directional notch, an inner facet) — within the form language and the character family. Without it the re-skin reads as "the same primitive, just rounder."
- **Shading model** — flat / single-direction gradient / glow halo — pick one, apply everywhere. Asserting it isn't executing it: if it's "flat + glow halo," actually draw the halo.
- **Scale & padding** — how each asset maps to its primitive's footprint, with consistent internal padding (e.g. all art in a square canvas at the same % padding).

Recorded verbatim in `asset_pass.visual_system` so it's reviewable and the thing a run report critiques when the result looks incoherent.

## The swap mechanism (the technically hard part — shared by both methods)

The builder draws procedurally: `Main.tscn` is a bare `Node2D` with all rendering in `Main.gd`'s `_draw()` — **no sprite slots to swap into**. So you both produce textures *and* rewire.

**a) Get textures into Godot.** Run a headless import pass so the `.import` sidecars + cached textures exist **before** re-validating:
```
godot --headless --path games/<id>/ --import
```
Commit the generated `*.import` sidecars alongside the art (expected Godot output, like `.gd.uid`).

**b) Two swap strategies** (the choice is itself a finding to record in `asset_pass.notes`):
- **`draw_texture*` in place — lighter, preferred for the builder's default single-`_draw()` games.** Replace each actor's `draw_rect`/`draw_circle` with `draw_texture_rect()`/`draw_texture()` *inside the existing `_draw()`*, loading the texture once in `_ready()`. Preserves z-order, the shake transform, and squash/stretch for free — no node surgery.
- **Retained `Sprite2D`/`TextureRect` nodes — for node-based scenes or per-actor nodes** (world actors → `Sprite2D` at the primitive's transform; HUD/UI → `TextureRect` under the HUD layer). On an immediate-mode game this needs three non-obvious steps the naive "just add a Sprite2D" misses:
  1. A parent's `_draw()` renders *below* its children. Keep the **background** in the root `_draw()`, but move anything that must sit *above* actors (HUD, particles, crash-flash) into a higher-`z_index` child that delegates back (e.g. an `Overlay` Node2D whose `_draw()` calls `draw_overlay(self)` on Main). Else the HUD vanishes under the sprites.
  2. **Hoist screen-shake into shared per-frame state** (compute the offset once in `_process`, add it to every sprite's `position` *and* the background `draw_set_transform`) — a node transform doesn't inherit the `_draw()` transform.
  3. **Pool one node per spawned actor** (grow an `Array`, show/hide per live instance; `modulate` per instance for a tinted family from one texture).

**c) Remove or guard** the matching `_draw()` for each re-skinned entity — delete its `draw_rect`/`draw_circle`/glow calls; keep the node's transform and all logic. Verify no double-draw. Also delete **stale glow-halos sized for the old primitive** — behind a larger sprite they read as an odd disc artifact.

**d) What stays code.** Effects (glow, particles, screen-shake, squash/stretch, flash) stay code — they're *juice*, not art. Record which entities you re-skinned vs. left primitive (`reskinned`/`left_primitive`) so a partial pass is a legible choice, not a silent gap. **A primitive background is a cohesion gap, not a free pass** — the raster method generates a themed background (see Backgrounds); if you leave it primitive you must justify it in `notes`.

**Failure attribution (the POC value):** a bad re-skin is always attributable — a weak texture, a mis-positioned/mis-scaled sprite, or a left-in primitive. Each is a specific, fixable prose gap.

---

# The `raster` method (representational art via local SD)

Produces **RGBA sprites** (native transparency at generation time) SVG can't do well. The deliverable is still a sharp **system**: every "this looks bad" must trace to a fixable cause — a weak scaffold, wrong style profile/param, a mis-placed sprite, a left-in primitive, or an *infra* failure in `comfy.mjs` — never an unattributable blob.

## Prerequisite (assumed running, like Godot)
ComfyUI runs headless as a local server (default `http://127.0.0.1:8188`) with an SDXL checkpoint + the **ComfyUI-layerdiffuse** node. The owner starts it; this skill doesn't manage it. Confirm reachability + see checkpoints:
```
node tools/comfy.mjs --check
```
If it prints `UNREACHABLE`, **stop** and ask the owner to start it. A failure here is *infra*, attributable to the stack — never work around it by faking a PNG.

**Stack-version sensitivity.** ComfyUI-layerdiffuse is version-fragile: on a bleeding-edge ComfyUI it silently drops its model patch (`patch type not recognized` → haze) and errors on the alpha-join. If sprites come back as haze or a desaturated/gray interior (correct alpha, flat colour), that's a **stack-version** issue, not your recipe — check the server log for patch warnings and confirm the pin/patch from `docs/superpowers/m1.5-feasibility-notes.md` are in place before touching the recipe.

## Step 0 (raster) — style as a first-class choice
Do the normal Step 0, plus:

**(a) Select the per-game style profile explicitly.** Style is a *first-class, per-game parameter* — it's what lets one skill make different-looking games. From `art_direction`, choose a **checkpoint** (painterly vs. flat-cartoon vs. pixel-art finetune), optional **LoRA(s)**, and the **style fragment** (e.g. `"painterly, illustrated, soft brushwork"`). Justify "this art_direction → this profile" as you justify the visual system. Record in `asset_pass.visual_system.style` (`{checkpoint, loras[], style_prompt}`). Two games *should* look deliberately different — that's the goal, not a failure.

**(b) Fix the shared prompt scaffold.** One base prompt (style fragment + shared scene/lighting terms) and one fixed sampler/steps/cfg. **Every** sprite is `scaffold + this actor's subject`, so the set reads as one family. Record in `asset_pass.visual_system.prompt_scaffold`. Always include `"single centered subject, full body, clean transparent background"` in the scaffold, and put scene/multiplicity terms — `"scene, multiple characters, frame, border, ring, wreath, ground, floor, shadow"` — in the shared `negative`. Without this, an over-described minor prop comes back as a wreath/row-of-blobs; the negatives don't fire if the positive prompt itself invites a scene.

Incoherence has two kinds: **style** divergence (caught by profile/scaffold/params) and **subject-world** divergence (caught by the world bible). A cyan-robot hero next to a red-ogre hazard is the latter — a finding about the world bible, never about one PNG.

## Audit every generation against intent — subject, tone, cross-asset cohesion
A diffusion model does **not** reliably draw what you asked. **Read every PNG and judge it against intent before accepting** — regenerate, don't ship "close enough" — on three axes:

- **Subject fidelity** — is this the *thing* you asked for? (e.g. "a small impish fire-demon" rendered a tall winged demoness.) When it drifts, **tighten the subject phrase** (make the intended thing the explicit sole subject, add concrete shape/scale words like "small, squat, hunched, oversized head") and add **anti-drift negatives** for what it became. **A named asset must depict the thing it names, recognizably at a glance — that's gameplay legibility, not just style.** A card called "Chain Lightning" must read as chained forked lightning, not a generic "arcane sigil" (a proven failure: abstracting a spell into an ornamental medallion left *no lightning in it at all* — the player can't tell what it does). Name the literal effect as the sole subject; negative out the generic-icon attractors (`medallion, emblem, sigil, rune circle, badge, gemstone, ornamental icon, symmetrical`) when they hijack it. Audit by asking *"could a player name this from the art?"*
- **Tone fidelity** — does it match the title's *mood*? Subject-right isn't enough: a corrected "small imp" can come back cute/chibi when the world wants sinister. Pull tone with mood words in the positive, the wrong tone in the negative (`cute, adorable, chibi, mascot` to banish; `menacing, sinister, grotesque, fanged` to invite). Tone lives in `concept.theme` — judge against it, not in the abstract.
- **Cross-asset cohesion — judge each asset *against the others*, not in isolation.** A shared style fragment is necessary but not sufficient: the same words land in different rendering registers depending on subject. **Diffusion pulls representational subjects (creatures, characters) toward photo-realism harder than abstract subjects (effects, sigils)** — so one fragment can render an effect-card as painterly but a creature as semi-photoreal, and side by side they don't cohere even though palette + words matched. Pick the asset whose style the owner approved as the **reference** and conform the others to *that specific register*, regenerating the reference too so you compare the locked style to itself. **De-realism ≠ flatten:** if the defect is photoreal *anatomy*, remove *only* the photoreal attractor (`photorealistic, hyperrealistic, realistic human skin, detailed musculature, 3d render, octane render`) and **keep the reference's painterly qualities** (`hand-painted illustration, painterly rendering, soft volumetric lighting, glowing aura`) — over-swinging to `cel-shaded, flat color, thick outlines` makes a flat mascot that's incoherent in the *opposite* direction. Match the reference's level of rendered detail and glow, not a generic flatness. "Same medium" is **not** cohesion: apply the one-hand test on the specific sub-axes — finish/render level, line weight, detail density, mood — *"would one illustrator have drawn both?"* — and watch for **whack-a-mole** where each regen fixes one axis and slips another. The fix isn't to keep swapping which asset is "too much": lock ONE finish register up front (name its finish/line/detail), conform every asset to it at once, and judge a true side-by-side.

The audit extends to the **composited render**, not just the raw PNG — when code draws chrome over the art, eyeball the assembled widget for layout collisions/clipping too (see the visual-audit skill — composition-collision and legibility lenses). "The art is good" ≠ "the screen is good."

Lever order per regen: subject/tone phrase → negatives → `master_resolution`/`width,height` → `cfg ±1`. Keep the *style* fragment + params fixed (cohesion); only subject/tone/negatives move.

## When the base model FIGHTS the style, swap the checkpoint — don't out-prompt it
The highest-leverage style lever is the **checkpoint**, not the prompt. A photoreal base (e.g. Juggernaut XL) will keep dragging representational subjects toward realism no matter how many `2D, flat, cel-shaded` terms + anti-`3d/photo` negatives you stack — that's a property of the weights, not the prompt; each regen fixes one axis and slips another. When 3–4 honest style regens still read wrong *in the same direction* (too rendered / gritty / realistic), stop out-prompting and **swap to a checkpoint whose native output already IS the target** (a flat-cartoon / illustration / anime SDXL finetune, e.g. Cartoon Arcadia XL). One swap does what a dozen prompt iterations can't, and it **solves cross-asset cohesion for free** — every asset inherits the model's one hand, so the creature-vs-effect whack-a-mole disappears.
- **Source one anonymously (no token):** query the Civitai API — `curl -s "https://civitai.com/api/v1/models?limit=20&types=Checkpoint&baseModels=SDXL%201.0&tag=cartoon&sort=Most%20Downloaded"` → parse `items[].name` + `modelVersions[0].files[0].downloadUrl`, then `curl -L --fail -o models/checkpoints/<name>.safetensors "<downloadUrl>"` (307-redirects to a B2 CDN, auto-issued token). You need a **single-file** `.safetensors`; HF diffusers-format repos (separate `unet/`,`vae/` folders) won't load in `CheckpointLoaderSimple`.
- **Gate it before the batch:** ComfyUI picks up a dropped checkpoint without restart (mtime rescan). Generate ONE sprite and confirm (a) the look is the target and (b) the **LayerDiffuse alpha-join is clean** (no haze/gray-interior matte) — a non-standard finetune can break the join. Record the chosen `checkpoint` in every recipe + `asset_pass`; it's now part of the locked visual system.
- Style words still matter — they now *reinforce* a willing model instead of fighting a hostile one (keep `flat bold cartoon, clean thick outlines, vibrant cel shading` positive, `anime, manga` negative for Western-not-anime).

## Abstract-effect subjects collapse — anchor to an actor, POV, or the world
An abstract effect ("forked chain lightning, no figures") is one of the worst subjects for an opaque SDXL card: the model's "fantasy art" distribution is scenes and characters, so a figure-less effect collapses to the nearest in-distribution thing — a random landscape, an invented caster, a weak scattered web, or literal trees from "branching." Don't burn a dozen gens fighting it. Give the model a subject it renders reliably **and** that ties to the game:
- **Actor-driven** — show the game's protagonist *performing* the effect (a recurring, consistently-described figure — same costume/palette every time — so the set coheres like a TCG's hero).
- **First-person POV (strong lever)** — frame it as the effect *leaving the actor's own hand* ("first-person POV down the caster's outstretched hand, `<effect>` bursting from the palm"). Reads instantly as the ability, and strips rendered-figure/background detail so it sits closer to a sprite's simplicity (helps cohesion).
- **World-anchored** — set it in the game's actual environment, not a model-picked vista; ties it to the world bible.
- Still audit with "could a player name this?" — an actor holding *fire* on a card named Chain Lightning is still a miss; negative the wrong element, name the right one.

## Per-entity flow
For each entity you make raster:
1. **Recipe** — compose JSON: `prompt = scaffold + this actor's subject` (the subject is *this actor as a member of the world-bible family*, never free-standing); plus `negative`, `seed`, `sampler`, `steps`, `cfg`, `checkpoint`, optional `lora`, `layerdiffuse:true`, `master_resolution`. Keep `sampler`/`steps`/`cfg` identical across the game's sprites. A `%lora%` template requires `lora` set; for a no-LoRA profile use a template that omits the token (an absent `lora` against a `%lora%` template fails loudly by design — attributable, not a bug).
   - **Proven defaults (feasibility gate):** an **SDXL finetune** as `checkpoint` (not base `sd_xl_base_1.0`, which renders flat/washed-out through LayerDiffuse). `sampler:"euler"`, `cfg:7–8`, `steps:20–25`. The LayerDiffuse templates bake the working FG-RGBA settings (`SDXL, Conv Injection` + scheduler `normal`); `Attention Injection`/`karras` produced mud in testing. `master_resolution`: 1024 for a hero/large actor, 512 for a minor prop — always downscale from the master.
   - **Optional levers (low-ROI vs. backgrounds — reach for backgrounds/sizing first):** `"scheduler":"karras"` (still unproven on GPU — confirm by eye, given the `karras`+`Attention Injection` "mud" finding); `"refine":true` routes to a 1.5× upscale + denoise-0.45 second pass (~1536² master — alpha-join GPU-verified clean, but the gain is marginal, so it's a crispness / high-DPI lever, not a fix for a "bad" sprite). `refine`+`lora` together is unsupported.
2. **Generate** — `node tools/comfy.mjs gen <id> <name> '<recipe-json>'` → writes `games/<id>/art/<name>.png` (RGBA). On a graph/unreachable error it fails loudly — fix the infra/recipe, don't fake the file.
3. **Import** — `godot --headless --path games/<id>/ --import` so the `.png.import` sidecar + cached texture exist **before** re-validation.
   - **Re-run `--import` after EVERY regeneration that overwrites an existing PNG, or Godot serves a STALE cached texture** (a regenerated sprite kept rendering as the old one because the cached `.ctex` wasn't invalidated). Overwriting in place doesn't reliably trigger re-import on a headless `--script`/screenshot run. Treat "regenerate → `--import` → render/validate" as one atomic sequence.
4. **Configure mobile import settings** (see Resolution & mobile density) — edit `<name>.png.import` so it's mobile-grade, then re-run `--import`.
5. **Rewire** — per the swap mechanism above: prefer `draw_texture*`-in-place; place at the primitive's footprint; remove/guard the primitive (no double-draw); logic untouched.
   - **Variable-width actors: tile exact-fit units, never stretch.** Fill a runtime-variable width by tiling N = `round(w / unit_size)` units that each fit exactly, so visual width matches collision width. Stretching a fixed-aspect sprite distorts it and misaligns visual vs. collision bounds.
   - **Tab-indented GDScript breaks exact-match edits.** The builder's GDScript uses tabs; the Edit tool's exact-match often fails on tab/space ambiguity. Reliable workaround — splice via PowerShell (`Get-Content`/`Set-Content` preserve tabs):
     ```powershell
     $lines = Get-Content path/Main.gd
     $out = $lines[0..($a-1)] + $new + $lines[($b+1)..($lines.Count-1)]  # replace 0-based [a..b]
     Set-Content path/Main.gd $out
     ```
     For a single line, `$lines[$i] = 'new line'` then `Set-Content`. Prefer this over repeated Edit retries when a splice isn't landing.

## Backgrounds & composition (where art quality actually lives)
Playtests proved sprites are usually already fine; "terrible" comes from **flat primitive backgrounds + heroes too small**, not sprite quality. So generate environment art and size the hero deliberately.
- **Background = full-frame OPAQUE image (no LayerDiffuse).** Use the plain `sdxl` template: `layerdiffuse:false`, no alpha, explicit non-square `width`/`height` matching the game's aspect (e.g. `1280×768` landscape, `768×1280` portrait — `comfy.mjs` honors distinct `width`/`height`). The prompt expresses `theme.setting` as a *scene/environment* ("a cozy autumn-woodland glade, soft depth, storybook") — the same world the sprites inhabit. Draw it as the **bottom layer** (root `_draw()` background, or a full-rect `Sprite2D` at `z_index` below all actors), replacing the flat primitive band/void. Record as a `reskinned` background, `origin:"raster"`. This **supersedes** the old "background left primitive is a deferred gap" default — a themed background is now in scope and expected.
- **Size the hero for the frame.** A detailed sprite floating tiny reads cheap. Place the hero to occupy a *prominent share* of its play area and clearly larger than/distinct from hazards. Sizing is a *runtime scale at wire time* (the `Sprite2D` scale / `draw_texture_rect` dest size), not a generation param — hitboxes untouched. Record the intent in `notes`.
- **Pixel-art backgrounds: the opaque `sdxl` template has NO LoRA node.** A pixel-art *sprite* uses `sdxl-layerdiffuse-lora` to apply `pixel-art-xl`; the opaque background template carries no `%lora%`, so get the pixel look from **prompt terms** ("pixel art, 8-bit, NES, chunky pixels") + the project's **NEAREST** texture filter. Record the LoRA-absence as a recipe `note`.
- **Full-playfield games: a background only fixes the MARGINS.** For a title whose playfield fills the screen (a lane-crosser whose flat lane bands ARE the frame), a full-frame background only enriches the visible margins — the flat playfield itself still reads flat. Fully fixing that needs **lane/surface tile textures** (a different technique, which also risks the lane-colour *readability* the gameplay depends on). Don't speculatively retexture a functional playfield — ship the margin/sizing win, record the lane-tile opportunity, let the owner direct.

## Text & chrome over full-bleed art
When a card/panel uses a **full-bleed painted illustration** (opaque art filling the rect, no authored frame) and code draws the gameplay text on top, the **generated PNG carries no border/panel/text** (those would bake in wrong values and fight legibility) — all chrome is code-drawn at runtime so one renderer serves every card:
- **A defined semi-transparent SOLID panel behind each text block — not a gradient scrim alone. This is the project-wide legibility primitive, not a card-only trick** — move 4's legibility pass applies it everywhere code draws text over non-uniform art (HUD, pile counts, floating combat numbers, banners, tooltips), not just cards. A gradient fades to transparent and so fails over a *bright* patch of art ("the text is hard to read"). A solid panel (`draw_rect` ~`Color(0.05, 0.04, 0.11, 0.80)`) gives **consistent** contrast regardless of what the model painted underneath; feather just its leading edge with a short gradient quad so it doesn't hard-cut into the painting. One panel for the bottom effect block, one for the top name.
- **Drop-shadowed text** (draw the string once near-black at +1px, then in the real colour).
- **Element border + cost badge + pip** stay code-drawn over everything, drawn *last* (gameplay-critical at-a-glance identity).
- **Scale text with the widget, not absolute px** — derive font sizes + chrome geometry from `rect.size` (e.g. `s = rect.size.y / base_h`), or big cards (reward cards, a 2× detail view) show tiny text.
- **Chrome-layout QA — audit the composited widget for collisions/clipping**, every state (affordable / unaffordable / selected) and the largest size: no element overlaps another (center the name in the space *right* of the cost badge, not under it), text fits its panel and isn't clipped by the card edge, the cost/border/pip stay clear of the text. A layout collision is an attributable chrome bug, exactly like a subject/tone drift.
- Immediate-mode gradient-quad helper (per-vertex colours): `draw_polygon(corners, [c_top,c_top,c_bot,c_bot])`.

## Mixed-method honesty
If an actor is genuinely better as crisp vector or a primitive — a HP bar, a geometric pickup, a HUD frame — you may leave it `svg`/`primitive`, and you must **say so** (record per-entity origin so a partial pass is a legible choice, not a silent gap). **When an actor fights the medium, mixed-method is the right call, not a cop-out:** a tiny or effect-like sprite (a ~14px glowing pickup) SDXL can't render coherently across retries is better as a procedural primitive (a glow-mote `draw_circle`). Vary subject phrase → `master_resolution` (1024→512→256) → `cfg ±1`; after 3–4 variations without a clean output, leave it primitive and record the finding. (This does **not** license crude code icons next to painted art — see the fidelity-cohesion bar in the visual-audit skill (fidelity-cohesion lens); mixed-method is for genuine medium-fights, not for skipping fidelity.)

## Resolution & mobile density (recovering what SVG gave for free)
SVG covered every Android density bucket (mdpi → xxxhdpi) from one file; raster forfeits that, so replace it deliberately or the output is **not** app-store-ready:
- **Generate high-res masters** sized for the largest bucket the asset occupies (a generous power-of-two: **512²** minor prop, **1024²** hero actor). Always **downscale from the master**, never upscale.
- **Set mobile import settings explicitly** in each `.png.import`: `mipmaps/generate=true` (clean minification), a linear `filter`, a 2D-mobile compression (lossless for small sprite counts; VRAM-compressed if the title grows). Don't accept Godot's defaults silently. Record in the recipe's `import_settings` (`{mipmaps, filter, compression}`).
- **Pixel-art crispness:** set `process/size_limit` in the `.png.import` to a small target (64/128) so Godot resamples the 1024 master down cleanly at import, then draw with `TEXTURE_FILTER_NEAREST` (mipmaps off) to keep chunky pixels crisp. Don't draw a raw 1024 master tiny with nearest filtering — the alias noise is severe.
- **Footprint mapping is unchanged at runtime** — the texture scales to the primitive's on-screen footprint; the master being *larger* than that footprint is correct high-DPI headroom, **not** waste to "fix" by shrinking the master.
- Texture **atlasing** and whole-title APK **size budgeting** are **M2** packaging concerns, out of scope here. Generating proper masters now is what makes that step possible.

## Content & IP safety
SDXL can emit outputs resembling trademarked/copyrighted characters — an app-store rejection and legal risk:
- Put IP guards in **every** recipe's `negative`: `"logo, watermark, text, trademarked character, brand, celebrity likeness"`.
- Keep prompts to **generic descriptors** — never name a franchise, studio, or character.
- The **human A/B is the safety review** — the owner confirms nothing looks like protected IP before `styled`. (Outputs owned for commercial use under the SDXL Community License revenue threshold; re-verify the threshold at ship time.)

## Determinism
The committed **PNG is canonical** — a fresh clone runs identically. `recipes[]` is **provenance, not a bit-exact regeneration guarantee**: GPU matmul + RNG are non-deterministic, so the same recipe regenerates a *close* image, never the same pixels. "I have the seed" ≠ "I can reproduce the art."

---

# The `svg` method (geometric / UI / flat)

Use when the branch sent you to `svg` — abstract, geometric, neon/flat, hyper-casual, all UI, where vector resolution-independence is a real win (one file covers every Android density bucket). One file per builder-registered entity under `games/<id>/art/` (`player.svg`, `obstacle.svg`, …), every file conforming to the Step 0 system: same palette, stroke, form language, shading, `viewBox`/padding.
- Use a square `viewBox` (e.g. `0 0 100 100`) so scaling to a footprint is predictable.
- **Execute the shading model** — if it's "flat fill + outer glow halo," actually draw the halo (an oversized low-alpha shape behind, or an SVG `<filter>` blur). Asserting neon isn't executing neon.
- Keep files small and diffable — paths, `<rect>`, `<circle>`, gradients, filters. No embedded rasters.
- Rewire via the shared swap mechanism (`draw_texture*`-in-place preferred). Godot imports `.svg` as a texture via a `.svg.import` sidecar — commit it.

If a concept's `art_direction` leans representational enough that hand-authored vector would be weak, that's the signal you should be on the `raster` method — don't ship mediocre vector art to dodge generation.

---

## Recording the pass

1. Flip the re-skinned `assets[]` entries (arrays replace wholesale — pass the **full** array, re-skinned as `origin:"raster"|"svg"`, untouched as-is):
   ```
   node tools/manifest.mjs merge <id> "{\"assets\": [ {\"type\":\"sprite\",\"name\":\"hero\",\"source\":\"art/hero.png\",\"origin\":\"raster\"}, ... ]}"
   ```
2. Write the `asset_pass` block (record the Step 0 system verbatim). The `raster` method additionally carries the style profile, the shared scaffold, and one recipe per generated PNG (arrays replace wholesale — pass the full `recipes[]`):
   ```
   node tools/manifest.mjs merge <id> "{\"asset_pass\": {\"method\":\"raster\",\"visual_system\":{\"world_bible\":\"...\",\"palette\":[...],\"form\":\"...\",\"shading\":\"...\",\"scale\":\"...\",\"prompt_scaffold\":\"...\",\"style\":{\"checkpoint\":\"...\",\"loras\":[...],\"style_prompt\":\"...\"}},\"reskinned\":[...],\"left_primitive\":[...],\"art_path\":\"games/<id>/art/\",\"notes\":\"...\",\"recipes\":[{\"name\":\"hero\",\"checkpoint\":\"...\",\"prompt\":\"...\",\"negative\":\"...\",\"seed\":123,\"sampler\":\"euler\",\"steps\":24,\"cfg\":7,\"master_resolution\":1024,\"layerdiffuse\":true,\"import_settings\":{\"mipmaps\":true,\"filter\":\"linear\",\"compression\":\"lossless\"}}]}}"
   ```
   (For `svg`, set `method:"svg"` and omit `style`/`prompt_scaffold`/`recipes`.)
3. Validate the manifest (still `playable` at this point): `node tools/manifest.mjs validate <id>` → expect `<id> OK`.

## Hand off to visual-audit
Do **not** set `styled` yourself. Hand off the rewired game to the `visual-audit` skill, which judges the composited running screen (inventory / fidelity-cohesion / composition-collision / legibility / colour-accessibility lenses) and drives the fix → re-render → re-audit loop. It in turn hands to `validator`, which re-runs the mechanical gates (headless import + run clean; `selftest.gd` still `SELFTEST OK` if present; human A/B playtest) and advances `playable → styled` on success, or records legible `issues` (attributed to `asset` or to chrome-code) and stops on failure.

## Notes
- The `--import` pass must run before the validator's headless run, or `load("res://art/...")` returns null at runtime.
- If a re-skin looks *worse* or incoherent, that's a finding about the **visual system** (Step 0), not the individual files — fix the system and re-derive, don't patch one asset.
