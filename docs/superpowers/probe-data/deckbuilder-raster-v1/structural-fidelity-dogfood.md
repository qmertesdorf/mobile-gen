# Structural Fidelity lens — RED/GREEN dogfood (2026-06-05)

Validation artifact for the 7th `visual-audit` lens (`references/structural-fidelity.md`).
Target: the `deckbuilder-0001` run map (`structural-fidelity-dogfood-map.png`, rendered via the
throwaway `_shot.gd` harness, RUN_SEED, 1280×720).

## RED (already established)
The map reads "nonsensical," yet the six pre-existing lenses (inventory, fidelity, composition,
legibility, colour-accessibility, polish) all pass or only graze it — they are pixel-only and
self-referential, so none knows the nodes are *supposed* to form aligned lanes you ascend. That gap
is exactly why this lens exists.

## GREEN (this dogfood)
A fresh subagent was given ONLY `references/structural-fidelity.md` + the map PNG + a structure brief
(structure kind, intended grammar: floor=row bottom→top, col=lane, edge=legal move; the full
ground-truth node/edge instance from the seed; the player's task). It was NOT told where any bug was.

It independently surfaced, attributed (`chrome-code-layout`) and with concrete fixes:
- **[blocker] axis-2 Consistent spatial grammar** — per-floor-width normalization (`col/(width-1)`)
  pins col0 to the far-left edge and col1 to the far-right, so columns never form lanes and a single
  edge spans the full 1280px. (This is the exact root cause in `MapView._node_center()`.)
- **[blocker] axis-3 Traceability & figure/ground** — floors don't read as horizontal rows;
  bottom→top progress is unreadable; edges cross the whole frame.
- **[blocker] axis-1 Faithful encoding / false adjacency** — LOOT (floor 1) drawn stacked directly
  on FIGHT (floor 0) because both col0 nodes land on the same left-edge x.
- **[major] axis-3** — long full-width crossing edge chains defeat reachability.
- **[minor]** — rubber-stamp guard fired: it named what *does* read (the current-node ring +
  gold available-edge), proving it discriminates a faithful element from a broken screen.

Verdict: **NOT faithful + NOT traceable — FAIL (hard gate)**; single highest-leverage fix = replace
per-row normalization with one **global column lattice** (`x = left_margin + col*lane_pitch`, lanes
sized to the map's max width). This matches the design's predicted fix.

## N/A guard
A second fresh subagent was given the same reference + a **combat** frame
(`runlayer-final/combat_polished.png`) and **no structure brief**. It correctly returned **N/A**,
quoted the scope rules, and explicitly refused to manufacture structure from the card row. The scope
guard works.

## Conclusion
The lens fires precisely on the relational screen, catches the structural defect the other six lenses
miss, stays in scope (excludes paint/text), and returns N/A on non-relational screens. Shipped
without revision. The map *fix* itself (global lattice + backdrop scrim + reveal the journey) is a
separate, owner-deferred track.
