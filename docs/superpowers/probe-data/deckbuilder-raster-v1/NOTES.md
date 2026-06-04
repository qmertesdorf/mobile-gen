# Deckbuilder raster art — Phase 0 probe v1 (data points)

Date: 2026-06-02. Kept at the owner's request as useful data points (do not delete).

These are the **first** Juggernaut XL v9 probe outputs for the shippable raster art pass,
before subject-fidelity tightening + the legibility-panel chrome change.

## What they are
- `enemy_imp_v1.png` — seed 201, the shared SPRITE scaffold + subject "a small impish fire-demon
  with curved horns, bat wings, a barbed tail, glowing amber eyes, an ember aura".
- `card_chain_lightning_v1.png` — seed 301, the shared CARD scaffold ("single iconic spell
  illustration, dramatic centered composition, arcane backdrop") + subject "forked arcs of
  violet-white lightning chaining through the air".
- `probe-card_v1.png` — the composite (imp + the card rendered full-bleed with the v1 gradient-only
  scrim chrome at 1x/2x/selected).

## Owner findings (why v1 was not locked)
1. **Style** ✅ — both read as shippable "stylized modern arcane"; palette cohesive; clean
   LayerDiffuse transparency on the imp. Style profile is good.
2. **Card legibility** ❌ — gradient-only scrims are not enough; text is hard to read where the
   art is bright. Fix: add a **defined semi-transparent solid panel** behind the text block so it
   reads regardless of the underlying image.
3. **Subject fidelity** ❌ — the imp rendered as a tall **winged demoness**, not a small imp; the
   card rendered as a **canyon landscape with one bolt**, not chain lightning. The CARD scaffold's
   "dramatic centered composition, arcane backdrop" biases toward scenic landscapes. Fix: make the
   spell-effect/creature the explicit sole subject + add anti-landscape / anti-glamour negatives,
   and **audit every generation against intent**, regenerating when it drifts.
