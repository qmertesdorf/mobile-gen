---
name: visual-audit
description: Use when judging the composited, assembled screen of a running Godot game — "does it look designed and read clearly?" — typically after the asset re-skin (before validator's styled gate) or standalone on any running game. Renders every game state, fans out one fresh auditor subagent per lens (inventory/completeness, fidelity/cohesion, composition/collision, legibility, colour-accessibility, structural-fidelity, polish/design-quality), dedupes + attributes findings, and drives the fix → re-render → re-audit loop. Records NOTHING to the manifest — outputs are code fixes (git) + a findings report.
---

# visual-audit

Grade the **assembled, running screen** of a Godot game — not the raw asset files. "The art is good" ≠ "the screen is good": a re-skin that nails every PNG still ships unfinished if a primitive HUD, an unreadable value, an icon-over-the-name collision, or a colour-blind-hostile state survives. This skill is the composited audit, extracted from `asset` so it is reusable on ANY running game and so independent fresh eyes — not the person who made the fix — render the verdict.

```
… → [playable] → asset (produce + asset_pass) → visual-audit (this skill) → validator(re-run) → [styled]
```

Also invocable standalone: point it at any running game to grade its screen.

## What this skill does NOT touch
- The per-PNG generation audit (subject/tone/cohesion of each generated image → regenerate) lives in `asset`; it runs at generation time and drives re-generation.
- Game logic. Fixes are visual (chrome code, import settings) or routed back to `asset` as regen requests. If a `selftest.gd` exists it must still print `SELFTEST OK` after fixes — and if a `uitest.gd` exists it must still print `UITEST OK`: audit fixes edit view/chrome code, which is exactly where taps silently break (mouse-filter shadowing, z-order, lost signal wiring), and no pixel lens can see input routing.
- The manifest. This is a transient gate: its outputs are code fixes (captured in git) and a findings report to the owner. The validator asserts "did the gate pass" via the human A/B when it advances to `styled`.

## Workflow

**1. Render every game state — not just one frame.** On the REAL renderer (NOT `--headless`; the dummy renderer cannot capture pixels). Reuse the `tools/godot/screenshot.gd` capture pattern, or write a throwaway harness that drives the game into each state and captures the viewport. **Enumerate the states and capture each as its own frame:** the busiest combat/gameplay state (full hand/HUD, statuses up, intent shown), AND each modal/overlay (every reward/shop screen, win, lose, map/rest). "Busiest state" reads as busy *combat* and the overlays then go un-audited — a real reward-overlay title shipped on bare scrim because only the combat frame was captured. Drive a deliberately cluttered state so every chrome element is present at once. Throwaway harness/crops are deleted at the end; preserve one representative post-fix frame under the game's dir if useful.

**2. Magnify — never judge from the downscaled frame.** Two elements 6px apart and two overlapping by 6px look identical at 1×/2×; the verdict only exists at the boundary. Crop + upscale tight regions to 3×+ with PowerShell `System.Drawing` (NearestNeighbor) before calling any pairing.

**3. Inventory setup pass (lens 1, runs first).** Walk the renderer top-to-bottom and produce the element + state map per `references/inventory-completeness.md`. This map is the input the six parallel lenses consume.

**3a. Structure brief (setup pass, for relational screens only).** If a captured screen has **relational / topological structure** (a map / tree / board with meaningful adjacency / ordered list), the orchestrator (you, here — NOT the lens subagent) reads the **model + generator + layout source** and emits a **structure brief** for that screen: the structure kind; the intended spatial grammar (what a row/column/edge *means*); the ground-truth instance (node list with floor/col/type, edge list, current node, reachable set); and the player's task. This is the ONLY place source/model is read — it keeps the Structural Fidelity lens pixel-only and its eyes fresh. A screen with no relational structure gets **no brief**, and the lens returns **N/A** for it.

**4. Fan out — one FRESH auditor subagent per parallel lens.** After the inventory setup pass (step 3), dispatch the **six** parallel-lens subagents concurrently — one per lens (Agent tool), each handed ONLY its reference + the rendered frames + the inventory map, each told to return a structured finding list and to default to FINDING when unsure:
- `references/fidelity-cohesion.md`
- `references/composition-collision.md`
- `references/legibility.md`
- `references/colour-accessibility.md`
- `references/structural-fidelity.md` *(hard gate; consumes the structure brief; N/A when none)*
- `references/polish-quality.md`

Independent fresh eyes per lens is the whole point: the intent-dagger-over-name and the dark-on-dark-numeral bugs both slipped past passes that *had the rules*, because one self-reviewing reviewer rationalises "minor." Do not collapse the lenses into one self-read.

**Five lenses catch DEFECTS (hard gates — fidelity, composition, legibility, colour-accessibility, and structural-fidelity); polish-quality grades DESIGN (is it good?).** A screen can pass every defect lens and still be flat/generic/default-positioned — polish-quality is the only lens that sees that gap. But it is **advisory, cost-triaged — NOT a hard gate**: its findings carry a `cheap/medium/expensive` cost tag; fix the cheap ones in the pass, and **surface medium/expensive composition changes for the owner to decide** rather than treating them as blockers. Don't let "redesign the whole layout" stall a defect pass.

**5. Collect, dedupe, attribute.** Merge the lens findings; dedupe (the same collision may surface from composition AND legibility); attribute each to a cause — `asset-production` (weak/missing/mis-styled art → regen request back to asset), `chrome-code` (a `_draw()`/styling fix), or `chrome-code-layout` (placement/grouping/anchoring/sizing — the polish lens's usual cause). A bad screen is always attributable; an unattributable "looks off" is not a finished finding. Keep the polish lens's cost tags through the merge so the owner can triage what to fix now vs. defer.

**6. Fix → re-render → re-audit LOOP.** Apply fixes, then RE-RENDER and RE-AUDIT against the *new* frames, because (a) code-right ≠ screen-right and (b) fixes spawn new issues (a repositioned element creates a fresh collision; a newly-styled panel exposes a primitive hidden behind the old one). Re-audit with FRESH eyes — ideally a fresh subagent that did NOT make the fix. Never call the pass done off the screenshot you *fixed against*; call it done off a clean re-audit of the screenshot that came *after* the fixes.

**7. Report.** Summarise findings (each attributed) and the resolution to the owner. Write nothing to the manifest. Hand off to `validator` (or back to `asset` if regen is needed).

## Mipmaps — the grain fix (do this before blaming the art)
An asset authored ornate at high res and drawn into a small UI slot (a 768×1024 texture at 44px) **aliases into grain** with no mipmaps. Godot's importer defaults `mipmaps/generate=false`; set it **`=true`** in each downscaled texture's `.png.import` and re-import, AND set the canvas filter to a mipmap variant (`CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS` on the drawing Node2D) — mipmaps need *both*. This de-grains every downscaled draw. Even so, a busy source thumbnails worse than a bold simple one — author small-display elements with fewer, larger shapes + thick outlines. **Verify the DOWNSCALED result at true size**, not the full-res PNG.

## The lenses
| Lens | Reference | Runs |
| --- | --- | --- |
| Inventory & completeness | `references/inventory-completeness.md` | setup (first) |
| Fidelity & cohesion | `references/fidelity-cohesion.md` | parallel |
| Composition & collision | `references/composition-collision.md` | parallel |
| Legibility | `references/legibility.md` | parallel |
| Colour-accessibility | `references/colour-accessibility.md` | parallel |
| Structural fidelity | `references/structural-fidelity.md` | parallel (hard gate; relational screens only) |
| Polish & design-quality | `references/polish-quality.md` | parallel (advisory, cost-triaged) |
