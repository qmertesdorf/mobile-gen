# visual-audit Skill Split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the composited-running-game audit out of `asset/SKILL.md` into a new standalone `visual-audit` skill (a short spine + one `references/<lens>.md` per lens), leaving `asset` as a focused production skill.

**Architecture:** New skill dir `.claude/skills/visual-audit/` with `SKILL.md` (process spine: render every game state, fan out one fresh auditor subagent per lens, dedupe + attribute findings, drive the fix→re-render→re-audit loop, report — no manifest write) and `references/` holding 5 lens checklists (1 setup: inventory/completeness; 4 parallel: fidelity/cohesion, composition/collision, legibility, colour-accessibility). The per-PNG "judge each generation against intent" audit STAYS in `asset` (it drives regeneration). Cross-references in `asset`, `README.md`, `CLAUDE.md` updated; `validator` verified.

**Tech Stack:** Markdown skill files (Anthropic Agent-Skills format: a skill is a dir with `SKILL.md` + optional `references/`). No code, no schema change, no manifest block. Validation is `writing-skills` RED/GREEN: dispatch fresh auditor subagents at known-buggy frames in `docs/superpowers/probe-data/deckbuilder-raster-v1/` and confirm each lens catches its bug class.

**Naming note:** The skill name is `visual-audit` throughout (locked).

**Source of truth for moved prose:** the CURRENT `.claude/skills/asset/SKILL.md` (256 lines). The composited-audit block is **lines 146–186**. The per-PNG audit (lines 103–113) STAYS. Exact line anchors are given per task. When moving a passage, move it **verbatim**, then rewrite only the dangling cross-references called out in that task so each reference file is self-contained.

---

## File Structure

- **Create** `.claude/skills/visual-audit/SKILL.md` — process spine (frontmatter + workflow + fan-out + loop + mipmap fix + report). New content (Task 1).
- **Create** `.claude/skills/visual-audit/references/inventory-completeness.md` — lens 1 setup (Task 2; source: asset 149–150).
- **Create** `.claude/skills/visual-audit/references/fidelity-cohesion.md` — lens 2 (Task 3; source: asset 151–166).
- **Create** `.claude/skills/visual-audit/references/composition-collision.md` — lens 3 (Task 4; source: asset 167–170 + 172–175).
- **Create** `.claude/skills/visual-audit/references/legibility.md` — lens 4 (Task 5; source: asset 176).
- **Create** `.claude/skills/visual-audit/references/colour-accessibility.md` — lens 5 (Task 6; source: asset 177–181).
- **Modify** `.claude/skills/asset/SKILL.md` — delete the composited-audit block (146–186), fix description + handoff + loop diagram + cross-refs (Task 7).
- **Modify** `README.md`, `CLAUDE.md`; **verify** `.claude/skills/validator/SKILL.md` (Task 8).
- **Validate** RED/GREEN + asset coherence (Task 9).

Reference files are plain markdown (NOT `SKILL.md`), so they are NOT auto-discovered as skills — no YAML frontmatter; a `#` title + one-line purpose is enough.

---

### Task 1: Scaffold `visual-audit` and write the spine `SKILL.md`

**Files:**
- Create: `.claude/skills/visual-audit/SKILL.md`

- [ ] **Step 1: Create the skill dir and SKILL.md with this exact content**

```markdown
---
name: visual-audit
description: Use when judging the composited, assembled screen of a running Godot game — "does it look designed and read clearly?" — typically after the asset re-skin (before validator's styled gate) or standalone on any running game. Renders every game state, fans out one fresh auditor subagent per lens (inventory/completeness, fidelity/cohesion, composition/collision, legibility, colour-accessibility), dedupes + attributes findings, and drives the fix → re-render → re-audit loop. Records NOTHING to the manifest — outputs are code fixes (git) + a findings report.
---

# visual-audit

Grade the **assembled, running screen** of a Godot game — not the raw asset files. "The art is good" ≠ "the screen is good": a re-skin that nails every PNG still ships unfinished if a primitive HUD, an unreadable value, an icon-over-the-name collision, or a colour-blind-hostile state survives. This skill is the composited audit, extracted from `asset` so it is reusable on ANY running game and so independent fresh eyes — not the person who made the fix — render the verdict.

```
… → [playable] → asset (produce + asset_pass) → visual-audit (this skill) → validator(re-run) → [styled]
```

Also invocable standalone: point it at any running game to grade its screen.

## What this skill does NOT touch
- The per-PNG generation audit (subject/tone/cohesion of each generated image → regenerate) lives in `asset`; it runs at generation time and drives re-generation.
- Game logic. Fixes are visual (chrome code, import settings) or routed back to `asset` as regen requests. If a `selftest.gd` exists it must still print `SELFTEST OK` after fixes.
- The manifest. This is a transient gate: its outputs are code fixes (captured in git) and a findings report to the owner. The validator asserts "did the gate pass" via the human A/B when it advances to `styled`.

## Workflow

**1. Render every game state — not just one frame.** On the REAL renderer (NOT `--headless`; the dummy renderer cannot capture pixels). Reuse the `tools/godot/screenshot.gd` capture pattern, or write a throwaway harness that drives the game into each state and captures the viewport. **Enumerate the states and capture each as its own frame:** the busiest combat/gameplay state (full hand/HUD, statuses up, intent shown), AND each modal/overlay (every reward/shop screen, win, lose, map/rest). "Busiest state" reads as busy *combat* and the overlays then go un-audited — a real reward-overlay title shipped on bare scrim because only the combat frame was captured. Drive a deliberately cluttered state so every chrome element is present at once. Throwaway harness/crops are deleted at the end; preserve one representative post-fix frame in `docs/superpowers/probe-data/<id>/` if useful.

**2. Magnify — never judge from the downscaled frame.** Two elements 6px apart and two overlapping by 6px look identical at 1×/2×; the verdict only exists at the boundary. Crop + upscale tight regions to 3×+ with PowerShell `System.Drawing` (NearestNeighbor) before calling any pairing.

**3. Inventory setup pass (lens 1, runs first).** Walk the renderer top-to-bottom and produce the element + state map per `references/inventory-completeness.md`. This map is the input the four parallel lenses consume.

**4. Fan out — one FRESH auditor subagent per parallel lens.** Dispatch four subagents concurrently (Agent tool), each handed ONLY its reference + the rendered frames + the inventory map, each told to return a structured finding list and to default to FINDING when unsure:
- `references/fidelity-cohesion.md`
- `references/composition-collision.md`
- `references/legibility.md`
- `references/colour-accessibility.md`

Independent fresh eyes per lens is the whole point: the intent-dagger-over-name and the dark-on-dark-numeral bugs both slipped past passes that *had the rules*, because one self-reviewing reviewer rationalises "minor." Do not collapse the lenses into one self-read.

**5. Collect, dedupe, attribute.** Merge the lens findings; dedupe (the same collision may surface from composition AND legibility); attribute each to a cause — `asset-production` (weak/missing/mis-styled art → regen request back to asset) or `chrome-code` (a `_draw()`/layout fix). A bad screen is always attributable; an unattributable "looks off" is not a finished finding.

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
```

- [ ] **Step 2: Verify the file exists and frontmatter is well-formed**

Run: `node -e "const fs=require('fs');const t=fs.readFileSync('.claude/skills/visual-audit/SKILL.md','utf8');const m=t.match(/^---\n([\s\S]*?)\n---/);if(!m)throw new Error('no frontmatter');if(!/name: visual-audit/.test(m[1]))throw new Error('bad name');if(!/description:/.test(m[1]))throw new Error('no description');console.log('SPINE OK')"`
Expected: prints `SPINE OK`

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/visual-audit/SKILL.md
git commit -m "feat(visual-audit): scaffold standalone composited-audit skill spine"
```

---

### Task 2: Reference — inventory & completeness (lens 1, setup)

**Files:**
- Create: `.claude/skills/visual-audit/references/inventory-completeness.md`

- [ ] **Step 1: Create the file with this header, then the moved passage**

Header (new):
```markdown
# Lens: Inventory & completeness (setup pass)

Used by the `visual-audit` skill. Runs FIRST and feeds the other lenses. Walk the renderer top-to-bottom, classify every drawn element, and produce the missing-asset list + element/state map.
```

Then append, **verbatim from `asset/SKILL.md` line 149–150** (the paragraph beginning `**1. Inventory EVERY drawn element**`). Rewrite the lead `**1. Inventory EVERY drawn element**` → `**Inventory EVERY drawn element**` (drop the move number). No other cross-refs to fix in this passage.

- [ ] **Step 2: Verify self-contained**

Run: `grep -nE "Move [0-9]|see below|this auditor" .claude/skills/visual-audit/references/inventory-completeness.md || echo "CLEAN"`
Expected: `CLEAN` (no dangling move/see-below refs). If any appear, rewrite them to name the sibling lens or `the asset skill`.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/visual-audit/references/inventory-completeness.md
git commit -m "feat(visual-audit): inventory & completeness lens"
```

---

### Task 3: Reference — fidelity & cohesion (lens 2)

**Files:**
- Create: `.claude/skills/visual-audit/references/fidelity-cohesion.md`

- [ ] **Step 1: Create the file with this header, then the moved passage**

Header (new):
```markdown
# Lens: Fidelity & cohesion

Used by the `visual-audit` skill (parallel). Does every drawn element hold the painted-art bar and belong to one hand? Judged at TRUE on-screen size, against the painted art — not against the other code tokens.
```

Then append, **verbatim from `asset/SKILL.md` lines 151–166** (Move 2: the paragraph beginning `**2. Hold every code-drawn element to the hero-art bar…**` through the `**Code-token red flags**` block and the `**Token framing & crop integrity…**` paragraph — i.e. everything up to but NOT including line 167 `**3. Scan for visual bugs**`). Rewrite the lead `**2. Hold every code-drawn element…**` → `**Hold every code-drawn element…**` (drop the move number). This passage also covers composited-level "theme/world read" — leave as-is.

- [ ] **Step 2: Verify self-contained**

Run: `grep -nE "Move [0-9]|asset-by-asset" .claude/skills/visual-audit/references/fidelity-cohesion.md || echo "CLEAN"`
Expected: `CLEAN`. If a `Move N` ref remains, rewrite to the sibling lens name.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/visual-audit/references/fidelity-cohesion.md
git commit -m "feat(visual-audit): fidelity & cohesion lens"
```

---

### Task 4: Reference — composition & collision (lens 3)

**Files:**
- Create: `.claude/skills/visual-audit/references/composition-collision.md`

- [ ] **Step 1: Create the file with this header, then the moved passages in this order**

Header (new):
```markdown
# Lens: Composition & collision

Used by the `visual-audit` skill (parallel). How elements sit together in space, and spatial render bugs. ENUMERATE element pairs and inspect each boundary in a MAGNIFIED crop — never judge from the downscaled frame.
```

Then append, in this order:
1. **Verbatim from `asset/SKILL.md` lines 167–170** — the `**3. Scan for visual bugs:**` paragraph. Rewrite lead `**3. Scan for visual bugs:**` → `**Scan for visual bugs:**`. It contains `a mis-cut token (see below)` → rewrite to `a mis-cut token (see the fidelity-cohesion lens)` and `grain from missing mipmaps (below)` → `grain from missing mipmaps (see the visual-audit spine's "Mipmaps" section)`.
2. **Verbatim from `asset/SKILL.md` line 172** — the `**Overlap / collision pass…**` bullet.
3. **Verbatim from `asset/SKILL.md` line 173** — the `**A painted icon's footprint is its ART…**` sub-bullet.
4. **Verbatim from `asset/SKILL.md` line 174** — the `**There is NO "minor" tier when a non-text element contacts TEXT.**` sub-bullet.
5. **Verbatim from `asset/SKILL.md` line 175** — the `**Text-over-element pass…**` bullet.

- [ ] **Step 2: Verify self-contained**

Run: `grep -nE "see below|Moves 1.3|asset-by-asset" .claude/skills/visual-audit/references/composition-collision.md || echo "CLEAN"`
Expected: `CLEAN` (the two `see below` refs from the visual-bugs paragraph must already be rewritten in Step 1).

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/visual-audit/references/composition-collision.md
git commit -m "feat(visual-audit): composition & collision lens"
```

---

### Task 5: Reference — legibility (lens 4)

**Files:**
- Create: `.claude/skills/visual-audit/references/legibility.md`

- [ ] **Step 1: Create the file with this header, then the moved passage**

Header (new):
```markdown
# Lens: Legibility

Used by the `visual-audit` skill (parallel). Can a player READ every text block and value at true size? The solid-backing primitive applies to ALL runtime text over non-uniform art, not just cards.
```

Then append, **verbatim from `asset/SKILL.md` line 176** — the `**Legibility-over-background pass — EVERY text block needs a guaranteed solid backing…**` bullet. It references `The full-bleed-card rule` — append this connective sentence so the reference is self-contained:

```markdown

> The full-bleed-card solid-panel rule it generalises is the production craft in the `asset` skill's "Text & chrome over full-bleed art" section: a DEFINED semi-transparent SOLID panel (e.g. `Color(0.05, 0.04, 0.11, 0.80)`), never a gradient-to-transparent scrim alone. Also fold in: legible numerals on cost gems / pile counts / status stacks must be crisp + high-contrast at true size (solid backing + shadow + size up; never dark-on-dark), and gameplay text uses one themed display font project-wide, not `ThemeDB.fallback_font`.
```

(That connective sentence pulls the "legible numerals + themed font" point — currently in `asset` Move 2 line ~156 — into the legibility lens where it belongs, so the lens covers all readability.)

- [ ] **Step 2: Verify self-contained**

Run: `grep -nE "see below" .claude/skills/visual-audit/references/legibility.md || echo "CLEAN"`
Expected: `CLEAN`

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/visual-audit/references/legibility.md
git commit -m "feat(visual-audit): legibility lens"
```

---

### Task 6: Reference — colour-accessibility (lens 5)

**Files:**
- Create: `.claude/skills/visual-audit/references/colour-accessibility.md`

- [ ] **Step 1: Create the file with this header, then the moved passages**

Header (new):
```markdown
# Lens: Colour-accessibility

Used by the `visual-audit` skill (parallel). Contrast + colour-blind safety, judged on the composite. Sibling of the legibility lens; structured separately so it can graduate to its own standalone skill later.
```

Then append, **verbatim from `asset/SKILL.md` lines 177–181** — the `**Colour-accessibility sweep…**` bullet and its four sub-bullets (Contrast ratio / Never encode meaning by hue alone / Differ in VALUE / Simulate it). No cross-refs to fix.

- [ ] **Step 2: Verify self-contained**

Run: `grep -nE "Move [0-9]|see below" .claude/skills/visual-audit/references/colour-accessibility.md || echo "CLEAN"`
Expected: `CLEAN`

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/visual-audit/references/colour-accessibility.md
git commit -m "feat(visual-audit): colour-accessibility lens"
```

---

### Task 7: Slim `asset/SKILL.md` — remove the moved block, fix refs

**Files:**
- Modify: `.claude/skills/asset/SKILL.md`

- [ ] **Step 1: Delete the composited-audit block (lines 146–187)**

Delete the entire section from `## Audit the composited, RUNNING game — not just the raw PNGs` (line 146) through the blank line after the Mipmaps paragraph (line 187), inclusive. Use a PowerShell splice (preserves the file's tabs/markdown):

```powershell
$p = ".claude/skills/asset/SKILL.md"
$lines = Get-Content $p
# Confirm boundaries before cutting:
"[146] $($lines[145])"   # expect: ## Audit the composited, RUNNING game ...
"[186] $($lines[185])"   # expect: **Mipmaps — the grain fix ...
"[188] $($lines[187])"   # expect: ## Backgrounds & composition ...
$out = $lines[0..144] + $lines[187..($lines.Count-1)]   # drop 145..186 (0-based) = lines 146..187
Set-Content $p $out
```

- [ ] **Step 2: Fix the description (line 3) — drop "audits the composited running game", route to visual-audit**

Replace `audits the composited running game, records asset_pass, and hands off to validator for "styled".`
with `records asset_pass, and hands off to the visual-audit skill (which judges the composited running game) ahead of validator's "styled" gate.`

- [ ] **Step 3: Fix the loop diagram (line ~12)**

Replace the line `concept → builder → validator → [playable] → asset → validator(re-run) → [styled]`
with `concept → builder → validator → [playable] → asset → visual-audit → validator(re-run) → [styled]`

- [ ] **Step 4: Fix the two remaining cross-references into the moved section**

Find and rewrite (these are in passages that STAY in asset):
- The per-PNG audit cross-ref (was line ~110): `(see "Audit the composited, running game")` → `(see the visual-audit skill)`.
- The mixed-method cross-ref (was line ~205): `the composited audit` → `the visual-audit skill (fidelity-cohesion lens)`.

Run to locate: `grep -nE "Audit the composited, running game|the composited audit" .claude/skills/asset/SKILL.md`
Then edit each hit per above. Expected after: that grep returns nothing.

- [ ] **Step 5: Fix the handoff section (was "## Hand off to the validator", ~line 251)**

Change the heading to `## Hand off to visual-audit` and rewrite its body so asset hands the rewired game to `visual-audit` (the composited audit + fix loop), which in turn hands to `validator` for the headless/selftest re-run + human A/B → `styled`. Keep the `selftest.gd` must still print `SELFTEST OK` requirement. Keep one sentence noting the `--import` pass must precede any render.

- [ ] **Step 6: Verify asset no longer contains audit-move prose and still has the per-PNG audit**

Run: `grep -nE "Inventory EVERY drawn element|Hold every code-drawn element|Composition, legibility & colour-accessibility|Overlap / collision pass" .claude/skills/asset/SKILL.md || echo "MOVED-OUT OK"`
Expected: `MOVED-OUT OK`

Run: `grep -nE "Audit every generation against intent|subject fidelity|cross-asset cohesion" .claude/skills/asset/SKILL.md`
Expected: still present (the per-PNG audit stays).

- [ ] **Step 7: Commit**

```bash
git add .claude/skills/asset/SKILL.md
git commit -m "refactor(asset): hand the composited audit to the new visual-audit skill"
```

---

### Task 8: Update README, CLAUDE.md; verify validator

**Files:**
- Modify: `README.md:11`
- Modify: `CLAUDE.md:17`
- Verify: `.claude/skills/validator/SKILL.md`

- [ ] **Step 1: README skill list (line 11)**

Replace `the \`concept\`, \`builder\`, \`validator\`, \`asset\` (re-skin/art), and \`audio\` (SFX+music) skills.`
with `the \`concept\`, \`builder\`, \`validator\`, \`asset\` (re-skin/art), \`visual-audit\` (composited-screen audit), and \`audio\` (SFX+music) skills.`

- [ ] **Step 2: CLAUDE.md skill-loop line (line 17)**

In the sentence `The \`asset\`/\`audio\` skills own the art/audio judgment;` change to `The \`asset\`/\`audio\` skills own art/audio production and \`visual-audit\` owns judging the composited screen;`

- [ ] **Step 3: Verify validator has no stale ownership of the composited audit**

Run: `grep -nE "composited|asset.*audit|owns the.*audit" .claude/skills/validator/SKILL.md || echo "VALIDATOR CLEAN"`
Expected: `VALIDATOR CLEAN`. If a hit appears, update it to reference `visual-audit` and note the change in the commit.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md .claude/skills/validator/SKILL.md
git commit -m "docs: insert visual-audit into the skill loop (README, CLAUDE, validator)"
```

---

### Task 9: RED/GREEN validation + asset coherence

This is the `writing-skills` discipline: prove each lens still catches its bug class after the move, using fresh subagents and existing frames. There are no automated unit tests for skills; the "test" is a subagent dispatch.

**Files:**
- Read-only: `.claude/skills/visual-audit/**`, `.claude/skills/asset/SKILL.md`
- RED frames: `docs/superpowers/probe-data/deckbuilder-raster-v1/*.png`

- [ ] **Step 1: Pick a RED frame per lens (open them; confirm the bug class is visibly present)**

Open candidates with the Read tool and choose one that clearly exhibits each lens's failure:
- fidelity/cohesion + legibility → an EARLY frame with flat code tokens / tiny text: `game_shot_v3.png` (or v1/v2).
- composition/collision → a frame with an element-on-text collision: scan `game_shot_v5.png`/`game_shot_v6.png`.
- colour-accessibility → any busy combat frame: `game_shot_v6.png`.
If no existing frame clearly shows a lens's bug, FALLBACK: render a RED frame from the current game by temporarily reverting one fix (e.g. `git stash` is not enough — instead checkout the pre-fix `CombatView.gd` for that bug, render with the harness from the spine, then restore). Record which frame you used for each lens.

- [ ] **Step 2: RED — dispatch one fresh subagent per lens at its RED frame**

For each lens, use the Agent tool (subagent_type `general-purpose`) with a prompt that gives ONLY: the lens reference file contents, the RED frame path, and "List every finding of THIS lens's class; default to FINDING when unsure. Do not assume the screen is fine." Do NOT tell it where the bug is.
Expected: the subagent independently reports the planted bug class (e.g. fidelity flags the flat code tokens; legibility flags the unreadable value; composition flags the element-on-text overlap; colour-accessibility flags a hue-only state). If a lens MISSES its bug, the reference lost a rule in the move — diff against the original `asset` lines and restore the missing sentence, then re-run.

- [ ] **Step 3: GREEN — dispatch the same lenses at a clean frame**

Frames: `game_shot_v8_post-audit-fix.png` and `reward_v8_post-audit-fix.png` (post this-session fixes).
Expected: each lens returns few/no findings of its class (a stray low-severity note is acceptable; a confidently-flagged real bug means either the frame isn't clean or the lens over-fires — investigate).

- [ ] **Step 4: Asset coherence check (fresh read)**

Read `.claude/skills/asset/SKILL.md` end-to-end. Confirm: (a) no dangling references to the moved section (grep from Task 7 Step 6 returns MOVED-OUT OK and the cross-ref grep returns nothing), (b) the per-PNG audit section is intact, (c) the handoff now points to `visual-audit`, (d) the loop diagram includes `visual-audit`. Fix any issue inline and re-commit.

- [ ] **Step 5: Commit any validation fixes**

```bash
git add .claude/skills/
git commit -m "test(visual-audit): RED/GREEN validate lenses catch their bug classes after the split"
```

(If no fixes were needed, skip the commit and note "validation passed, no changes" in the run report.)

---

## Self-Review (completed during planning)

- **Spec coverage:** boundary (Tasks 2–7) ✓; positioning between asset & validator (Task 1 spine + Task 7 handoff + Task 8 loop) ✓; no manifest record (spine "What this skill does NOT touch" + no schema task) ✓; spine + references + parallel fan-out (Task 1) ✓; 5 lenses 1 setup + 4 parallel (Tasks 2–6) ✓; cross-ref updates (Tasks 7–8) ✓; accessibility graduation-ready (Task 6 header note) ✓; RED/GREEN with probe-data frames (Task 9) ✓; theme→cohesion / per-PNG stays (Tasks 3, 7) ✓.
- **Placeholders:** none — every moved passage cites exact source lines; new prose is inline; the only latitude (Task 9 frame choice) is bounded with a fallback.
- **Naming consistency:** `visual-audit` used uniformly; reference filenames match the spine's lens table and every Task's create path.
