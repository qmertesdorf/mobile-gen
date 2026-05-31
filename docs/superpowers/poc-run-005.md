# POC Run 005 — A/B re-gen of the hybrid through the UPGRADED skills (match3-survival-0002, "Aegis Grid II")

**What this run is:** an A/B test, not a new genre. After run-004 exposed that the skills produced a *coexisting* (not *interlocked*) blend, the consolidated **skill-iteration pass** (`855b11a`) applied 5 deferred findings to `concept`/`builder`/`validator`. This run re-generates the SAME blend (match-3 + survival defense) through the edited skills to answer one question: **did editing the skill prose make the blend cohere?** It mirrors how `runner-0002` validated the run-001 quality edits.
**Final status:** playable
**Engine:** Godot 4.6.3.stable (headless clean at 120/600/3000; `selftest.gd` → `SELFTEST OK`, exit 0 — all verified independently of the builder subagent)

## The skill edits under test (committed `855b11a`)
1. `builder` — Godot-4.6 strict-typing rule (was carry-forward note; now in prose).
2. `builder` — "Hybrid / dual-loop concepts" rule (name the shared-resource contention; state the concurrency contract; make the cross-subsystem causal link salient; tune fairness on both axes).
3. `builder` — `selftest.gd` promoted from optional future hook to REQUIRED for logic-heavy genres.
4. `concept` — `core_loop` must state the player's moment-to-moment decision (agency) + a "Hybrid / combination concepts" rule requiring an explicit **forcing function**.
5. `validator` — new Method 1.5 runs `selftest.gd` as a live logic gate backing `core_loop_functional`.

## Owner verdict (the headline A/B result)
> "It's different but still not super coherent. It definitely has more of a blend than before, but still kinda not cohesive."

**Partial win — and that is a clean, informative result.** Against run-004's "basically match-3 with something random happening at the same time," v2 moved measurably toward a real blend. So:
- ✅ **The POC mechanism holds a third time.** Editing skill prose changed output in exactly the intended direction. Run-001→002 proved it for *quality*; run-004→005 now proves it for the hardest claim, *blend cohesion*. The manifest-as-spine + prose-as-tuning-knob thesis is robust.
- ⚠️ **The forcing-function rule alone is insufficient for full cohesion** (see Finding A). It got us a periodic interrupt, not a continuous fusion.

## Success criteria (§2)
1. Working project: **yes** — `games/match3-survival-0002/` (Main.gd + `selftest.gd`).
2. Ran without manual code fixes: **yes** — **0 game-code build iterations** (typing rule held a 3rd time; the only fix was a self-test *harness* lifecycle bug, not game logic — see Finding C).
3. Playable ~60s, core loop functions: **yes** — and `core_loop_functional` is now backed by an automated assertion, not just a human.
4. Manifest correct: **yes** — `validate` OK at every transition.
5. Failure legible & attributable to a skill: **yes** — Finding A is a precise, attributable next step.

## What the upgraded skills produced (the A/B evidence)
The builder, following the edited prose (not out-of-band notes — I deliberately withheld the findings this time to test the SKILL.md itself), implemented:
- **The forcing function:** every ~6s the enemy line telegraphs a heavy strike (red-hot lead chevron, shrinking countdown ring, danger vignette, center HUD "BLOCK! — match BLUE"); a blue match in the window triggers a cyan shield-flare that absorbs it (-4 HP), otherwise the wall craters (-34 HP + white flash + shake). This is the "drop your combo and defend" beat.
- **Salient, bidirectional causal links** (the run-004 fix): red matches fire bright tracers from each matched gem up to the line with a visibly dropping line-HP bar; blue matches flood the wall cyan and scale-pop the HP number.
- **Explicit, enforced concurrency contract:** the war advances during IDLE/SWAPPING/RESOLVING — you cannot pause it by dragging.
- **A passing `selftest.gd`** asserting the loop's logic (3-in-a-row clears; red lowers line HP; blue raises wall HP; defended vs. undefended strike differ; `_game_over()` fires on lethal breach).

The builder subagent's own assessment (it was NOT told the playtest verdict): the upgraded "Hybrid / dual-loop concepts" section "was the spine of this build … named the failure mode (coexist vs. fuse), demanded I make the causal link salient, told me to state the concurrency contract … all of which I implemented directly." Independent corroboration that the edit did its job at the builder layer — the residual gap is a *design-depth* gap, not a builder-compliance gap.

## Findings

### Finding A — `concept` (primary), HIGH value: cohesion needs *shared state/space*, not just a forcing event
- **What's still wrong:** The telegraph is a periodic **interrupt**. Between strikes the player is back to plain matching, so the two genres **alternate** (puzzle → defend beat → puzzle) instead of **fusing** into one continuous decision. A forcing *event* every 6s is better than nothing (run-004 had none), but it doesn't make every second a blended second.
- **Root cause:** The new "Hybrid / combination concepts" rule requires a *forcing function* and a *shared resource*, but in practice the shared resource was abstract ("the player's attention"), and the two subsystems still occupy **separate space** (threat on top, grid below) and run at **different tempos** (deliberate puzzle vs. real-time threat). Causal linkage ≠ fusion.
- **Proposed `concept` SKILL.md edit (next pass):** Strengthen the hybrid rule from "name a forcing function" to "prefer **state/space fusion**": the strongest blends make the two genres act on the *same objects or the same space*, so a single action serves both at once — e.g. the threat lives *on the grid* (enemies corrupt gems; the advancing line eats grid rows; threatened columns must be cleared to survive), so every match is simultaneously a puzzle move and a defense move. Add a **tempo-alignment** check: if the two genres' natural tempos differ, reconcile them (slow the real-time side toward puzzle tempo, or make matching faster/continuous) or they will read as two games sharing a screen. Periodic forcing events are a supplement, not the mechanism.
- **Honest caveat:** the owner deliberately chose the *hardest* blend (orthogonal puzzle + real-time). Some genre pairs may be intrinsically more cohesive than others; "fusion" guidance should help, but a single prose pass may not fully close an inherently hard pairing. Worth a third A/B with a state-fusion concept to confirm the rule moves the needle again.

### Finding B — POSITIVE: the `selftest.gd` logic gate works end-to-end
- The validator's new Method 1.5 ran the builder-emitted `selftest.gd`, got `SELFTEST OK`, and backed `core_loop_functional` with an assertion. For the first time in the POC, "the core loop is logically correct" is machine-verified, not just asserted by a human. This is the M0+ automation hook going from designed-for to live (for logic-heavy genres). The human playtest now confirms *feel/cohesion*; the self-test confirms *logic* — a clean division.

### Finding C — `builder`, LOW: self-test harness lifecycle gotcha (one iteration lost)
- The only fix iteration in the whole build was in `selftest.gd`: a `SceneTree` script that `add_child`s the game during `_init` finds `_ready()` deferred, so the board was empty when the first assertion ran. The builder fixed the harness (drive setup explicitly), not the game.
- **Proposed `builder` SKILL.md edit (next pass):** one sentence in the self-test section — "in a `SceneTree`/headless self-test, `_ready()` has not run yet when you add the game node; drive setup explicitly before asserting."

### Finding D — `builder`, LOW: telegraphed event vs. continuous threat is its own pattern
- The dual-loop section describes a *continuously advancing* threat; the *discrete, telegraphed* event (the thing that actually creates the "drop everything and defend" beat) is a distinct pattern the prose doesn't name. Worth one line so future hybrids reach for it deliberately.

## Where this leaves the POC
- **Combination claim:** upgraded from run-004's "half-proven / blends don't cohere" to "**the skills can push a blend toward cohesion, and prose edits measurably help — but full fusion needs a stronger concept rule (shared state/space + tempo), not just a forcing event.**" Net: the loop generalizes to combinations, and we now know the *specific* lever for making combinations feel like one game.
- **Automation:** the logic-gate half of the M0+ hook is live and proven (Finding B).
- **Mechanism:** prose-edits-as-tuning validated a 3rd time, now on the hardest axis.

## Next (owner deciding)
- [x] Mark match3-survival-0002 `playable`; commit run-005.
- [ ] (recommended) One more small `concept` edit (state/space fusion + tempo alignment, Finding A) → third A/B (Aegis Grid III, or a *different* blend designed for fusion, e.g. one where the threat lives on the board). Confirms the fusion rule moves the needle the way the forcing-function rule did.
- [ ] (cheap) Fold Findings C & D into `builder` whenever the next builder edit happens.
- [ ] (optional) Call the combination axis sufficiently demonstrated and return to breadth (a 4th distinct single genre) or wrap the POC.
