---
name: deepen
description: Use when growing an already-playable Godot game along a depth axis (systemic / content / run-meta) without regressing proven behavior. The first ITERATION skill in the GameForge loop — it EXTENDS the rules engine (the deliberate inverse of the asset re-skin's frozen-logic rule), TDD-ing each new sub-system against selftest.gd as a regression guard, records manifest.depth_pass, loops back through validator, and does NOT advance status.
---

# deepen

Take an already-playable game and grow it along ONE depth axis — systemic (new
interacting mechanics), content (more of the same), or run-meta (map / events /
economy / progression) — without regressing what already works, and **prove** the new
depth landed. Every other GameForge skill is build-once; `deepen` is the loop's first
in-place ITERATION skill.

## Loop position

```
prompt → concept → builder → validator → playtest → ( deepen → validator → playtest )*  → asset → visual-audit → audio → packager
```

`deepen` operates in place on a `validated`/`playable` game and loops back through the
validator. It does **not** advance status — a deeper game is the same status, just
bigger.

## Inputs
- A game at status ≥ `validated` with a working `games/<id>/selftest.gd`.
- A chosen depth axis + scope (spec-given, or assessed per the method below).

## Outputs
- Extended game code; a grown `selftest.gd`; a `manifest.depth_pass` record.
- Durable lessons folded back into this skill.

## The method

1. **Assess depth.** Name the axis the game is thinnest on and the single
   highest-leverage expansion. Don't widen three axes at once.
2. **Decompose into sub-systems.** Each one purpose, with a clean interface
   (data layer + logic + screen). Find the **extension seams**: where the existing code
   already supports growth (e.g. a static-func data table) vs. where you must
   **refactor to create a seam first** (e.g. a hardcoded linear sequence → a
   data-driven state machine). **Refactor-for-seam before adding content.**
3. **TDD each new system on the self-test — the validation spine:**
   - **`deepen` EXTENDS the logic; it does NOT freeze it.** This is the deliberate
     inverse of the `asset`/re-skin "logic FROZEN" rule. Confusing the two is the
     classic mistake — re-skinning must not touch rules; deepening is *all about*
     touching them, safely.
   - Existing assertions are the **regression guard**. `SELFTEST OK` must hold after
     every change — and `UITEST OK` too if a `uitest.gd` exists: deepening adds
     screens and controls, and a new view that renders fine can still swallow taps
     or skip its rebuild event (invisible to selftest, which bypasses the view).
     New tappable screens get new `uitest.gd` checks, same RED→GREEN discipline.
   - For each new system, **write its assertion first (RED) → implement → GREEN.**
     Prove new mechanics the same deterministic, headless way the original logic was.
   - **Never weaken or delete an existing assertion to make room.** If a new system
     genuinely changes old behavior, *surface it* — call it out and confirm it's
     intended — never silently overwrite the guard.
   - **A pure refactor adds no new behavior.** If the behavior it restructures isn't
     already covered, pin it with a **characterization assertion first** (one that
     passes both before and after the refactor), then refactor. Pure refactors add no
     *new-behavior* assertions.
4. **One sub-system at a time**, each independently self-tested and committed. Don't
   batch five then debug the soup. Keep a playable game at every step.
5. **Grow the UI per system**, reusing established chrome. Hand composited-screen
   judgment to `visual-audit` and correctness to `validator`. `deepen` owns *systems &
   content* — not pixels, not the gate mechanics. **New screens aren't self-test-gated**
   (the headless self-test never instantiates the scene tree), so gate them two other
   ways: a **headless boot check** (`godot --headless --path … --quit-after N`) that
   proves the router/view code parses and runs with no `SCRIPT ERROR`, plus a
   **throwaway real-renderer harness** (a `SceneTree` script that builds the relevant
   state, instantiates the view, waits ~200 frames, saves a PNG) for a visual sanity
   glance. Delete the throwaway; keep the PNG as a probe-data artifact.
6. **Record + codify.** Write `manifest.depth_pass` (axis, systems added, new-assertion
   count). Fold durable lessons back into this skill.

## manifest.depth_pass

```json
"depth_pass": {
  "axis": "run-meta | systemic | content",
  "systems_added": ["..."],
  "selftest_assertions_added": 0,
  "notes": "what changed, and any surfaced behavior-changes to previously-frozen logic"
}
```

## Boundaries / non-goals
- Not a re-skin (`asset` + `visual-audit`) and not the audio pass.
- Does not invent a new status or touch the packaging gate.
- Does not redesign from scratch — it grows what exists along one axis.

## Project gotchas (carry these)
- Headless `godot --script` does NOT instantiate autoloads → data layers via
  `preload` + `static func`.
- Seed every RNG; Fisher–Yates, never `Array.shuffle()`.
- Reset `user://save.json` before asserting on meta writes (stale-file false positives).
- A growing `selftest.gd` runs all stages in **one function scope** → give each stage's
  locals **unique names** (e.g. suffix with the stage number) or you get redeclaration
  parse errors as you append.
- Avoid GDScript method names that collide with `Object` built-ins (`connect`, `draw`,
  `set`, …) on your data/model classes — they parse-error or shadow silently.
- A new `manifest.depth_pass` field is **not free**: the manifest schema is
  `additionalProperties: false`, so add the field to `schema/manifest.schema.json` and
  re-run `node tools/manifest.mjs validate <id>` + the vitest suite before committing.

## Lessons from first use (run-layer dogfood)
- **The "surface, don't swallow" rule earns its keep.** Two changes touched
  previously-frozen combat logic — threading run-persistent HP through `setup()`, and
  giving a relic that had silently been a no-op a real effect. Both were named in
  `depth_pass.notes` rather than slipped in. When deepening forces a change to old
  behavior, that is normal — make it loud.
- **Prove the system headless first, wire the screen second.** Every sub-system landed
  its self-test assertion *before* any view existed, so the regression gate never
  depended on rendering. This ordering is what let view work stay a separate, lower-risk
  concern handed to `visual-audit`.
- **Check the acquisition path, not just the hook.** A hook that only fires at one
  moment (e.g. run-start) is dormant for anything acquired *after* that moment. When you
  add hook points, confirm the real in-game path that grants the thing actually triggers
  the hook — or record the limitation explicitly instead of shipping a dead feature.
