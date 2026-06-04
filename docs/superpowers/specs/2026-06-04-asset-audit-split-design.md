# Spec — Split the composited audit out of `asset` into a standalone audit skill

Date: 2026-06-04
Status: design approved (brainstorming), pending writing-plans.

## Motivation

`asset/SKILL.md` (256 lines) has grown to carry two genuinely different competences:

1. **Production** — derive a visual system, branch raster/svg, the swap mechanism (rewire
   `_draw()` → textures), per-entity generation, mobile import, recording `asset_pass`. Includes
   the **per-PNG audit** (judge each generated PNG against intent — subject fidelity, tone,
   cross-asset cohesion — and *regenerate if it drifts*), which is welded to the generate→regenerate
   loop.
2. **Composited-running-game audit** — judge the *assembled screen* of the live game (inventory
   every element, hold code-drawn chrome to the painted-art bar, scan visual bugs, composition /
   legibility / colour-accessibility sweep), looping fix → re-render → re-audit.

Making art and judging the running screen are different concerns with different inputs (a generation
recipe vs. a screenshot), different triggers, and different reuse profiles. The audit is the bulk of
recent growth and reads as a grab-bag inside a production skill. Separating it leaves both halves
more focused, and makes the audit **reusable on any running game, not just one freshly re-skinned**.

This is reversible (text + git), so we try it and revert if it doesn't pay off.

## The split (boundary)

**Moves OUT** to a new standalone skill — the composited-running-game audit only:
- The "Audit the composited, RUNNING game" section (current Moves 1–4).
- The audit *process*: capture every modal/overlay state, the fix → re-render → re-audit **loop**,
  fresh-eyes re-audit, and the mipmap/de-grain fix knowledge (a fix the audit applies/recommends).
- The composition / legibility / colour-accessibility sweep.

**STAYS in `asset`** (production + per-PNG):
- The per-PNG audit ("Audit every generation against intent — subject, tone, cross-asset cohesion"),
  because it drives regeneration inside the generate loop.
- All production craft: visual-system derivation, method branch, swap mechanism, per-entity flow,
  generation, mobile import/density, backgrounds, **"Text & chrome over full-bleed art"** (this is
  production *craft* — how to *build* legible chrome/solid panels; the audit *judges* the result).
- Content & IP safety, determinism, recording `asset_pass`.

**Shared concept (accepted minor duplication):** the solid-backing legibility primitive lives on both
sides — `asset` says "build chrome this way," the audit says "check it's present." Each states it from
its own side; we do not try to factor it into a third shared file.

## The new skill

**Name (locked):** `visual-audit` (judges the assembled screen — art + chrome + text + colour — of a
running game). Single-file-per-skill is the existing repo convention; this skill intentionally breaks it
with a `references/` subdir (new pattern here) to hold the lenses.

**Trigger / positioning in the loop.** Inserted as a visible phase between `asset` and `validator`:

```
… → [playable] → asset (produce + per-PNG audit + asset_pass) → visual-audit (composited audit, fix→re-render loop) → validator (re-run + human A/B → [styled])
```

Also **independently invocable** on any running game (no `asset_pass` required) to grade its screen.

**No manifest record.** The audit is a transient gate. Its outputs are (1) code fixes (captured in
git) and (2) a findings report to the user. The manifest only needs "did the gate pass," which the
*validator* already asserts when it advances to `styled` (human A/B). If we later need that gate
machine-checkable, we add a single verdict flag at that point — not a findings block, and not now
(YAGNI). This deliberately respects the audit's own rule that prior findings/classifications must be
**re-challenged from scratch**, which makes a persisted findings list write-only bloat.

### Structure: spine + per-lens references + parallel fresh-subagent fan-out

- **`SKILL.md` (short spine)** owns the *process*: reach/launch the game; enumerate the game states
  to capture (combat busy state, each reward/shop overlay, win, lose, map/rest); render each on the
  **real renderer** (the `tools/godot/screenshot.gd` capture pattern + a busy-state harness; PowerShell
  `System.Drawing` crop/upscale for true-pixel zoom); orchestrate the lenses; collect + **dedupe**
  findings; attribute each finding (asset-production vs chrome-code); drive the fix → re-render →
  re-audit **loop** until a clean pass; report. Holds the mipmap/de-grain fix knowledge.
- **`references/<lens>.md`** — one focused checklist per lens.
- **Main move = fan-out.** Run the inventory setup pass once, then spawn **one fresh auditor subagent
  per parallel lens**, each handed only its reference + the rendered frames + the inventory map; collect
  their findings. Fresh independent eyes per lens is the point: the intent-dagger-over-name and the
  dark-on-dark-numeral bugs both slipped past passes that *had the rules*, because one self-reviewing
  reviewer rationalizes "minor." This makes the skill's existing "fresh-eyes per concern" ideal the
  default. Cost: more machinery + tokens per audit than a single top-to-bottom checklist — accepted.

### Lenses (derived from current Moves 1–4): 1 setup + 4 parallel

1. **Inventory & completeness** *(setup — single holistic pass, runs first)* — walk the renderer
   top-to-bottom, classify every element (`art` / `code-chrome` / `primitive-that-should-be-art`),
   produce the missing-asset list, **re-challenge every inherited "code chrome" label from scratch**.
   Output: the element + state map the parallel lenses consume. *(current Move 1)*
2. **Fidelity & cohesion** *(parallel)* — does every element hold the painted-art bar? the one-hand
   test vs the painted art, finished-not-placeholder, the code-token red-flags, token crop/alpha
   integrity, re-roll discipline. Composited-level "theme/world read" folds in here. *(current Move 2)*
3. **Composition & collision** *(parallel)* — spatial relationships: enumerate element pairs, magnify
   each boundary, the painted-icon-footprint rule, **no-"minor"-tier when anything touches text**,
   z-order, grounding, double-draws, aspect-squish, mis-cut tokens. *(current Move 3 + Move 4 overlap /
   text-over-element passes)*
4. **Legibility** *(parallel)* — can a player *read* every text/value: the solid-backing primitive
   everywhere, contrast at true size, crisp numerals, themed font. *(current Move 4 legibility pass)*
5. **Colour-accessibility** *(parallel)* — contrast ratios, **never hue-alone**, differ-in-value-not-
   hue, grayscale / colour-blind simulation. *(current Move 4 accessibility sweep)*

**Seams.** Legibility (4) and colour-accessibility (5) are siblings (both touch contrast) but distinct
— "can you read it" vs "does it survive colour-blindness/glare." Kept separate so accessibility's
eventual **graduation to its own standalone skill** is a clean lift-out. **Theme** is not a separate
composited lens — at screen level it's "does the assembled thing read as the world" (Fidelity/Cohesion);
the subject-level theme check is the per-PNG audit that stays in `asset`.

## Cross-reference updates (part of the change)

- `asset/SKILL.md`: remove the composited-audit sections; change the description + "Hand off"
  section from "audits the composited running game … hands off to validator" to "hands off to
  `visual-audit`"; update the internal cross-refs (current lines ~110, ~205) that point at "Audit the
  composited, running game" to point at the new skill.
- `README.md` and `CLAUDE.md`: update the skill-loop prose to insert `visual-audit` between `asset`
  and the validator re-run.
- `validator/SKILL.md`: check for and update any reference to asset owning the composited audit.

## Testing / validation (writing-skills RED/GREEN)

The audit rules are hard-won from real misses, so the split must not lose them. Validate via the
`writing-skills` RED/GREEN discipline using **frames we already have**:
- RED cases from `docs/superpowers/probe-data/deckbuilder-raster-v1/` (pre-fix frames with the known
  dagger-over-name, dark-on-dark numeral, washed-out unaffordable text, cost-on-gem bugs).
- Confirm each lens subagent, given only its reference + a known-buggy frame (and NOT told where the
  bug is), catches its class of finding; confirm a clean post-fix frame yields a clean pass.
- Confirm `asset` still reads coherently as a production skill after extraction (no dangling
  references; the per-PNG audit still present and intact).

## Non-goals / YAGNI

- No manifest schema change (no `audit_pass` block, no verdict flag — until proven needed).
- Do **not** split the five lenses into five top-level skills (over-fragments coupled concerns,
  creates boundary gaps). They are references within one skill.
- Do **not** graduate accessibility to its own skill yet (structure it so we *can* later).
- No change to the per-PNG audit, generation pipeline, `comfy.mjs`, or game logic.

## Open items

- None — skill name locked to `visual-audit`; spec + plan approved.
