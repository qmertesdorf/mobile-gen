---
name: builder
description: Use when generating a runnable Godot 4.x project from a manifest's concept block. Produces games/<id>/, writes manifest.build, and sets status to "generated".
---

# builder

Generate a Godot 4.x project that opens and runs **without manual code fixes**, with a functional core loop, deliberate primitive visuals, and enough **game feel** that it reads as an intentional toy rather than a tech demo. "Runs without errors" is the floor, not the goal — a playtester should feel feedback on every action.

## Inputs
- `manifests/<id>.json` with a populated `concept` block (`status = "concept"`).
- The pinned Godot version from `README.md` (the source of truth for `engine_version`).

## Outputs
- A project under `games/<id>/`.
- A populated `manifest.build` block and `assets[]` entries.
- `status = "generated"`.

## Hard requirements
- The project MUST import and run headless with **no script errors** (the `validator` enforces this).
- Wire **touch/tap input** for Android (`InputEventScreenTouch` and/or `_input`), not just keyboard.
- Implement every mechanic listed in `concept.mechanics`, plus **game over + restart** so the loop is replayable.
- Keep one main scene runnable on launch (`run/main_scene` set in `project.godot`).
- Ship the **Game feel & juice** and **Tuning & fairness** requirements below — they are not optional polish, they are what separates "playable" from "terrible but playable".

## Staged build for systems-heavy genres (REQUIRED when the loop is too large to one-shot)

A turn-based deckbuilder, a tactics game, or any title with a rules engine + content DB + meta layer is too large to scaffold correctly in one pass — a one-shot produces a tangled `Main.gd` where rules and rendering are fused and nothing is testable. Decompose along the **rules/rendering seam** and build in dependency order, each stage gated by an assertion in `selftest.gd` before the next:

1. **Rules engine first, headless, pure.** A `RefCounted` (e.g. `CombatState.gd`) holding all state and rules — no nodes, no rendering, a **seedable** `RandomNumberGenerator` so runs are deterministic. Every rule (`play_card`, `end_turn`, `enemy_act`, win/lose) is a method that mutates state and returns a list of **events** (plain dictionaries) describing what happened. This is what `selftest.gd` drives.
2. **Content as data classes.** Card/enemy/item definitions live in data files (e.g. `data/CardDB.gd`, `data/EnemyDB.gd` returning typed Dictionaries) so the pool extends without touching the engine. Never inline content into the rules. **Reach them via `preload(...)` + `static func`, NOT autoload globals** — a headless `--script` self-test does not instantiate autoloads (see the turn-based self-test rules below), so autoload-based data is invisible to the test.
3. **Orchestration** (run/map/progression, e.g. `RunController.gd`) on top of the engine.
4. **Persistence** (`user://save.json` via a `MetaSave.gd`) — read at boot, write at the meta milestone.
5. **Rendering + juice LAST** (`CombatView.gd`): reads engine state, replays the engine's returned events as animations (tweens, pop-ups, shake, particles), and **never owns a rule.** If the view computes damage, the seam is broken — move it into the engine. **Event-contract completeness:** every engine method that mutates the phase/screen state MUST emit the transition event (e.g. `phase_changed`) — the view rebuilds *only* on events. A method that flips phase silently (shopkeep-0001: `start_day()` reached via Next Day / retry) leaves a dead stale screen, and it passes the state-level self-test AND per-screen pixel audits; only a real click-through catches it. Don't let an explicit `_rebuild_ui()` on the boot path mask a missing event on the loop path.

Build and self-test each stage before starting the next; commit per stage. The decomposition is the deliverable as much as the game — a fused build that "works" is a skill failure even if it runs.

## Deliberate primitives (no external art — that is M1)
Derive a coherent palette and shape language from `concept.art_direction`. Use in-engine drawing only: `ColorRect`, `Polygon2D`, `_draw()`, `Line2D`, simple `GPUParticles2D`/`CPUParticles2D`. Aim for *intentional* — clean shapes and a 3–5 color palette. Record each visual as an asset entry:
```
{ "type": "sprite", "name": "player", "source": "placeholder", "origin": "primitive" }
```

Compose a **layered scene**, not a flat field of rects (flat is the #1 cause of "looks terrible"):
- **Background layer:** never leave dead space. Add cheap depth — a subtle gradient, parallax lines/dots/stars that scroll slower than the play layer, or a faint grid.
- **Play layer:** the actors (player, obstacles, pickups).
- **HUD layer:** a **large, high-contrast** score read-out (top-center is safe), drawn last so it's always readable.
- **Glow recipe for "neon"/primitive shapes:** draw an oversized, low-alpha halo *behind* each shape (e.g. a rect/circle ~1.5–2× the size at ~15–25% alpha), then the crisp shape on top. Thick additive `Line2D` reads as a glowing edge. Asserting a neon palette is not enough — you must *execute* the glow.

## Game feel & juice (REQUIRED — wire at least these)
Every action needs feedback. Cheap, headless-safe techniques:
- **Impact on death:** a brief screen shake (offset the camera/draw origin by a decaying random vector for ~0.2s) and/or a full-screen flash.
- **Reward on score/milestone:** a quick scale-pop or color pulse on the score, or a particle burst at the actor.
- **Squash/stretch:** scale the player non-uniformly on jump take-off and landing (even ±15% for a few frames reads as life).
- **Responsive controls:** act on input immediately; for a jump, allow a short **coyote-time** window (~0.1s after leaving the ground) and/or input buffering so taps feel honored, not dropped.
Keep effects timer/tween-driven and reset cleanly on restart.

## Tuning & fairness (REQUIRED)
A loop that is unfair or arbitrarily paced reads as broken even when it "works":
- **Make every challenge clearable.** Derive limits from the player's own capabilities — e.g. compute jump airtime/horizontal reach and set the *minimum* obstacle spacing so a perfectly-timed input always succeeds. Never spawn an unavoidable obstacle.
- **Start gentle, ramp gradually.** Define an explicit starting difficulty (speed/spawn rate) and a slow ramp with a hard cap (`MAX_*` constants), so the first ~10s is forgiving and tension builds.
- Pull the intended curve from `concept.core_loop` if it specifies one; otherwise choose sane defaults and note them in a comment.

## Hybrid / dual-loop concepts (REQUIRED when `concept.genre` blends two genres)
A blended concept (e.g. "match-3 + survival") is still just another concept the steps below consume — but the scaffold and rules above assume a **single** actor/threat loop. When the concept fuses two subsystems, the dominant failure mode is **two systems that merely coexist on screen instead of fusing into one loop** — a playtester reads it as "genre A, with something random happening at the same time" (POC run-004). Wire the fusion deliberately:
- **Name and honor the shared-resource tension.** Identify the single resource both subsystems compete for (run-004: the player's matches — each swap could serve offense *or* defense). That *contention* is the game; make spending the resource on one subsystem visibly cost the other, so the player must choose.
- **State the concurrency contract explicitly** (in a comment): does the real-time subsystem keep advancing during the other subsystem's discrete actions (swaps / resolves / animations)? "It keeps advancing" is usually what creates pressure — but make it a deliberate, tuned choice, not an accident.
- **Prefer shared-space fusion over a periodic interrupt.** If the concept puts the threat *on* genre A's board (enemies corrupt gems, the advancing line eats grid rows), wire it so a single player action resolves in both subsystems at once — that's what makes seconds feel blended rather than alternating (POC run-005). A discrete, **telegraphed event** (a heavy strike every ~6s you must respond to) and a **continuously-advancing threat** (a line creeping forward every frame) are two *distinct* patterns: the telegraphed event creates a "drop everything and defend" spike but reads as an interrupt if it's the only coupling; the continuous threat creates steady background pressure. Reach for each deliberately, and lead with the continuous/shared-space coupling so the telegraph is a spike on top of fusion, not the sole link.
- **Make the cross-subsystem causal link SALIENT.** The player must see and feel that action A drove effect B — a bright tracer from the match to the threat, a wall pulse on repair, a number that visibly jumps. A correct-but-invisible link is exactly what reads as "random stuff happening at once."
- **Tune fairness across BOTH axes.** The dominant strategy must neither trivially win nor be unwinnable: a steady stream of the offense action should be *able* to out-pace the capped threat, while ignoring the defense action should reliably lose. Watch the threat/HP values over your 3000-frame headless run to confirm — and if the genre is logic-heavy, assert it in `selftest.gd` (below).

## Godot 4.6 GDScript typing (REQUIRED — this prevents build-error loops)
Godot 4.6 enforces strict typing and treats an inferred `Variant` as an error. Three consecutive POC runs lost (or would have lost) build iterations to exactly this, so follow it from the first draft — doing so took the two most logic-dense builds to **zero** build iterations:
- **Never `:=`-infer off a `Variant`-returning expression.** Indexing an *untyped* `Array`/`Dictionary` returns `Variant`; so do `clamp`, `lerp`, `min`, `max`, `abs` (even with float args). Annotate the receiving variable explicitly: `var x: float = clamp(v, 0.0, 1.0)`, `var c: Color = lerp(a, b, t)`, `var cell: int = grid[i]`.
- **`Array.filter()` / `Array.map()` return an *untyped* `Array`** — assigning to a typed `Array[T]` needs an explicit annotation or a rebuilt typed array.
- **Prefer typed containers** where natural (e.g. `var board: Array = []`), but always annotate the read site rather than relying on inference.

## Reference scaffold (adapt to the genre)

**Orientation (read from the manifest — do NOT hard-code).** Read `build.orientation` from `manifests/<id>.json`. **Absent or `"portrait"`** → `viewport_width=720`, `viewport_height=1280`, `window/handheld/orientation="portrait"` (the values shown below). **`"landscape"`** → `viewport_width=1280`, `viewport_height=720`, `window/handheld/orientation="landscape"`. Lay out the scene for the chosen frame: a landscape game uses the **width** (e.g. a fanned card hand along the bottom, actors staged left↔right); a portrait game uses height. The `concept`/manifest is the source of truth — never assume portrait. Write the build block including the orientation you used so the `validator`/`packager` pick the matching splash/screenshot dims (`splashSize(orientation)`).

`games/<id>/project.godot`:
```
config_version=5

[application]
config/name="<Title Name>"
run/main_scene="res://Main.tscn"

[display]
window/size/viewport_width=720
window/size/viewport_height=1280
window/handheld/orientation="portrait"
window/stretch/mode="canvas_items"
window/stretch/aspect="keep"

[input]
tap={
"deadzone": 0.5,
"events": []
}

[rendering]
renderer/rendering_method="mobile"
textures/vram_compression/import_etc2_astc=true
```

**Android export requirement (proven on a real Android export):** the `[rendering]` block above is mandatory for an Android build. `import_etc2_astc=true` is **required** — without it `godot --export-debug "Android"` fails the export validation with an empty/opaque "configuration errors:" message (the headless CLI does not name the cause; the editor's Export dialog does). `rendering_method="mobile"` (Vulkan) is the authored default and **runs** on real devices; note that the GL-compatibility renderer needs GLES 3 and that Android *emulators* often cannot drive either renderer (Vulkan → black, GLES3 → EGL crash), so emulators are an unreliable visual test for Godot — confirm visuals on desktop or a real device, not an AVD. (See `packager`/README "Android export" for the build seam.)

`games/<id>/Main.gd` (skeleton — fill the genre-specific loop):
```gdscript
extends Node2D

var score: int = 0
var alive: bool = true

func _ready() -> void:
	_start_game()

func _start_game() -> void:
	score = 0
	alive = true
	# spawn player + initial world here

func _input(event: InputEvent) -> void:
	# Android tap + desktop click both arrive here.
	if event is InputEventScreenTouch and event.pressed:
		_on_tap()
	elif event is InputEventMouseButton and event.pressed:
		_on_tap()

func _on_tap() -> void:
	if not alive:
		_start_game()
		return
	# core action (jump / shoot / swap ...) goes here

func _process(delta: float) -> void:
	if not alive:
		return
	# advance the world; on the loss condition call _game_over()

func _game_over() -> void:
	alive = false
	# show "tap to restart"
```

Create `Main.tscn` as a text scene referencing `Main.gd` on the root node, plus the primitive nodes the genre needs.

## Steps

1. Read `manifests/<id>.json`; confirm `concept` is populated.
2. Scaffold `games/<id>/` with `project.godot`, `Main.tscn`, `Main.gd`, and any extra scenes/scripts the mechanics need. Use the pinned `engine_version` from `README.md`.
3. Implement the core loop from `concept.core_loop` + `concept.mechanics`, including game-over + restart and touch input.
4. Apply the primitive visual style from `concept.art_direction` as a **layered scene** (background + play + HUD) with the glow recipe.
5. Wire the **Game feel & juice** feedback and apply **Tuning & fairness** (clearable spacing, gentle start + capped ramp).
6. Write the build block:
   ```
   node tools/manifest.mjs merge <id> "{\"build\": {\"engine\": \"godot\", \"engine_version\": \"<pinned>\", \"language\": \"gdscript\", \"project_path\": \"games/<id>/\", \"addons\": [], \"export_presets\": [\"android\"]}}"
   ```
7. Record primitive assets:
   ```
   node tools/manifest.mjs merge <id> "{\"assets\": [ ...primitive entries... ]}"
   ```
8. Advance status:
   ```
   node tools/manifest.mjs set-status <id> generated
   node tools/manifest.mjs validate <id>
   ```
   Expected: `<id> OK`. Hand off to `validator`.

## Notes
- Importing a `.gd` script generates a sibling `<name>.gd.uid` file. This is expected Godot 4.x output, not stray junk — commit it alongside the script.
- **`MOUSE_FILTER_PASS` does NOT pass input to siblings underneath.** The viewport hit-test stops at the topmost non-IGNORE Control under the point; PASS only bubbles the event to *ancestors*. A full-screen container Control with PASS layered over clickable siblings silently swallows every tap on them (shopkeep-0001: a 720×1280 patron-queue box over the shelf tiles killed all shelf taps). Pure container/overlay Controls must be `MOUSE_FILTER_IGNORE` — IGNORE skips only the box itself; its own children stay clickable.

## Self-test for logic-heavy genres (REQUIRED when the loop has non-trivial state logic)
"Runs headless without errors" does NOT prove the loop is correct — a match-3 with broken match-detection, or a hybrid whose offense match never actually damages the threat, will pass the programmatic gate and only fail a human (POC runs 002–004). For logic-heavy genres (puzzle/grid, state machines, multi-subsystem hybrids), emit `games/<id>/selftest.gd`: a headless `SceneTree` script that loads the game, drives the core action over N frames (drive state directly or synthesize `InputEvent`s — never wait on real input), ASSERTS observable state changes, then prints exactly `SELFTEST OK` and exits 0, or `SELFTEST FAIL: <reason>` and exits non-zero.

**Lifecycle gotcha (POC run-005):** in a `SceneTree`/headless self-test, when you `add_child` the game node its `_ready()` is **deferred** — it has not run yet on the line after `add_child`, so the board/world is still empty if you assert immediately. Drive setup explicitly (call the game's `_start_game()`/setup method yourself, or `await` a frame) before the first assertion. Fix the *harness*, not the game, when this bites.

**Turn-based / scripted-turn genres (deckbuilder, tactics, roguelike):** a real-time `_process` loop does not exercise a turn-based engine — drive **scripted turns** through the rules engine directly with a **fixed RNG seed**, and assert the full turn cycle. Think in turn-cycle *primitives*, not one genre's nouns; instantiate each primitive in your genre's terms:
- **Setup → opening state populated.** Seed the engine and start the encounter → assert the starting state exists (deckbuilder: opening hand drawn to its size; tactics: units placed on the board; roguelike: starting room/stats initialized).
- **Spend a resource for a primary effect → assert both.** Take the core offensive action → assert the resource was deducted **and** its effect landed (deckbuilder: a card costs mana and drops enemy HP by its value; tactics: a unit spends action points and its attack lands; RPG: an ability spends MP and hits).
- **Establish a state for later → assert it appears.** Take a setup action → assert the state it creates is present (deckbuilder: a damage-over-time or stacking status on the enemy; tactics: a buff/zone/marked target).
- **Exploit that state for a conditional payoff → assert the bonus branch.** Take the payoff action against that state → assert the **bonus** branch fired, not the base one (effect > base) (deckbuilder: a payoff card vs an afflicted target; tactics: bonus damage vs a marked/flanked unit).
- **End turn / opponent phase → assert the opponent acted AND time-based state advanced.** Resolve the turn → assert the opponent took its action (player state changed or was absorbed) **and** durational state ticked — applied and decremented (deckbuilder: a DoT dealt damage + decremented, a consumable status consumed; tactics: cooldowns/buff durations advanced; roguelike: a temporary effect expired).
- **Force the win condition → assert win + progression.** Drive the encounter to a win → assert the win-state (e.g. `is_won()`), then assert the post-encounter progression resolved (a reward choice advances the run, the next mission unlocks).
- **Force the loss condition → assert loss.** Drive the player to defeat → assert the lose-state (e.g. `is_lost()`).
- **Persistence milestone → assert the save wrote.** Drive the save trigger → assert the persistent file (`user://save.json`) was written with the expected keys.
Seeded RNG makes every assertion deterministic; the `validator`'s Method 1.6 runs this and `fail`s the build on `SELFTEST FAIL`.

Three hard rules for turn-based self-tests:
- **Headless `--script` runs don't instantiate autoloads.** `godot --script` starts a minimal SceneTree that skips the `[autoload]` section — `Engine.has_singleton("CardDB")` returns `false`, `/root/CardDB` is absent. Reach data layers (CardDB, EnemyDB, etc.) via `const X := preload("res://data/X.gd")` + `static func` only. Drop the `[autoload]` block from `project.godot` for any data file the self-test must reach, or make those files static-accessible so the self-test can preload them directly. (This silently breaks any turn-based build that expects autoload globals in its self-test.)
- **Seed every RNG path via a `RandomNumberGenerator` and shuffle with an explicit Fisher–Yates loop.** `Array.shuffle()` uses the global RNG and ignores any custom seed — deterministic assertions break silently. Use `rng.randi_range()` inside a manual Fisher–Yates on every shuffle that the self-test depends on.
- **Reset persistent side-effects before asserting on them.** If the self-test writes `user://save.json` (or any other file) and then asserts its contents, delete the file immediately before the write — a stale file from a prior run will false-positive the assertion without the write actually having occurred.

Assert what a human would check, e.g.:
- a known swap that should clear cells actually reduces the gem count / fires the match path,
- after a forced resolve the board has no floating gaps,
- an offense match lowers the threat's HP and a defense match raises wall HP (the hybrid's whole point),
- `_game_over()` fires when the loss condition is forced.
Keep it deterministic and headless-safe. The `validator` runs it automatically and will `fail` the build on `SELFTEST FAIL`. For a trivially simple arcade loop where a state assertion adds nothing, you may skip it — but say so explicitly in the build notes so the omission is a deliberate, legible choice, not a gap.

## Interaction self-test for tap/click-driven games (REQUIRED — emit `games/<id>/uitest.gd`)

A state-level self-test (drives the engine directly) and a pixel audit (judges renders) both miss a whole bug class: the screen looks right and the rules are right, but taps never reach handlers (mouse-filter shadowing, missing rebuild events — both shipped in shopkeep-0001 and survived every gate including the human playtest). For any game whose core loop is driven by tapping/clicking controls, emit **`games/<id>/uitest.gd`** alongside `selftest.gd` — its view↔input twin (`selftest.gd` proves the rules; `uitest.gd` proves a tap reaches them). The `validator` runs it (Method 1.7) and `fail`s the build on `UITEST FAIL`; view-mutating passes (asset / deepen / visual-audit fixes) re-run it before handoff. Reference implementation: `games/shopkeep-0001/uitest.gd`.

Contract and technique:
- A headless `SceneTree` script that boots `Main.tscn`, then walks the **full core loop with real clicks**: build `InputEventMouseButton` down+up pairs at each control's `get_global_rect().get_center()` and push via `root.push_input(ev, true)` (`in_local_coords=true` — the headless window ignores project size, so window-coord pushes get mis-stretched).
- After every click, assert **engine state** changed (resource collected, phase advanced, sale counted) — never assert only view internals; the point is proving input reaches the rules.
- Print one `UITEST PASS:`/`UITEST FAIL:` line per check, then exactly `UITEST OK` + exit 0, or `UITEST FAIL: <n> checks failed` + exit 1. (Track failures — a script that always exits 0 cannot gate anything.)
- Make outcome checks deterministic: fixed seed, and force the relevant state before an outcome-dependent click (e.g. set the patron's want to the shelf item you'll tap) — post-action UI resets make "did the tap land" ambiguous otherwise.
- If the test triggers a persistence write, clear the real `user://` save at start AND end so test state never leaks into the next boot.
- Cover at minimum: one tap per distinct control type, every phase/screen transition button, and the loop seam back to the start (e.g. next-day → first screen rebuilt).

Run your own self-test before handing off:
```
& "<godot exe>" --headless --path games/<id>/ --script res://selftest.gd
```
Expect exit 0 and `SELFTEST OK`. Fix the loop logic (not the assertion) until it passes.
