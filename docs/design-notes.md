# counta.click — UI/UX design notes

Working notes from the design phase (2026-08-03/04). The clickable reference is `assets/counta-prototype.html`; the canonical pen graphic is `assets/counta-pen.svg` (IDs + CSS-variable theming documented in its header comment).

## Locked decisions

- Two modes, one screen: pen setup is a one-time flow; daily use shows dose + remaining + "Dose now" only. The pen graphic is the constant anchor; flipping it to its back side IS the mode transition.
- Dose entry is dual-unit (mg/U ⇄ clicks) but **clicks are canonical** in the data model; units are derived display. The readout always leads with clicks — the action performed on the pen.
- Total clicks per pen: prepopulated from the product preset, user-overridable (custom pens).
- Click math reference (Wegovy 2.4 mg FlexTouch): 74 clicks = 2.4 mg dial; 4 doses/pen = 296 clicks = 9.6 mg / 3 mL. mg→clicks rounds to nearest; the app then displays the true mg for the chosen clicks (8 clicks ≈ 0.26 mg). Insulin FlexTouch: 1 click = 1 U (verify per product); Tresiba U200: 1 click = 2 U (verify).

## Dose-counter copy: numeric vs progress pens

Products need a `counter_style` flag:

- `numeric` (insulin FlexTouch): the window shows real numbers. Copy: "counter will show 12".
- `progress` (Wegovy, likely other GLP-1 FlexTouch): the window is binary — a 0/priming glyph, a long blank scroll, and the full-dose mark. Nothing readable in between; **the click count is the only measure**. Copy must not imply the window shows the dose.

Proposed copy for `progress` pens (dose readout, in order of preference):

1. `8 clicks` / "≈ 0.26 mg · the window shows no number — your click count is the dose"
2. `8 clicks` / "≈ 0.26 mg · dial sits about 1/9 of the way to the 2.4 mark" (position hint = digitized version of the dot-on-pen trick)
3. Confirmation modal: "Did you dial **8 clicks**? The scroll should sit just past the 0 mark."

Enhancement worth building: a mini window-scroll widget under the readout — a horizontal bar with the 0 glyph and full-dose mark, and a marker at `clicks / clicks_per_full_dose` (8/74 ≈ 11%) showing where the real dial should visually sit. Doubles as a sanity check before injecting.

## Pen flip ("spin") v2 — to really sell it

Current: label text squash-swaps, selector ribs shift 4 px. Needed:

- The **whole label sticker swaps**, not just the text: `#label-front` and `#label-back` each get their own sticker bg (back = plain white reverse sticker, no accent stripes), both scaleX-squashing through 0 at the midpoint.
- **Ribs travel far**: author extra ribs beyond both edges of the selector, clip with a mask to the selector rect, translate the rib group ~1.5 rib-spacings during the flip (then snap back — the eye can't tell). Same treatment for the insulin-scale ticks.
- **Counter window, dose pointer and dose text disappear** on the back (they're front-face features): squash/fade with the label.
- `prefers-reduced-motion`: instant swap, no travel.

## Multi-pen

- Accessible primary control: the header chip becomes a pen switcher — a real `<select>` (or ARIA listbox) listing pens as "Wegovy · 9.6 mg · 62%". Zero a11y risk, works tonight.
- Enhancement: swipeable carousel (per mockup, adjacent pens peeking) — `scroll-snap-type: x mandatory` + `scroll-padding` for the peek, each pen a focusable element in a listbox/tablist with roving tabindex and arrow-key support, changes announced via `aria-live`, chip stays in sync as the alternative input. Carousel is presentation; the chip/select remains the guaranteed path.

## History

The recent-doses list stays capped (5) on the main screen; "View all" opens a history modal: full log, basic filters (date range, this-pen/all-pens), **implicit missed doses** derived from frequency gaps (rendered as ghost rows, clearly inferred-not-recorded), and export (CSV + the ICS schedule).

## Mobile sizing silver bullet (prototype only)

Everything is px-sized; rather than a rem refactor before the real codebase exists:

```css
@media (max-width: 430px){ .app { zoom: 0.82; } }
```

`zoom` is supported in Chrome/Safari/Firefox 126+. Do the proper rem/container-query pass in the real codebase.

## Roadmap

Feature tracking lives in [GitHub issues](https://github.com/abradner/counta/issues), not this file.

**Anti-roadmap** — standing policy, so it stays here: no weight tracking, symptom dashboards, community feeds, AI coaching, or interaction checkers. Every GLP-1 app does these; they are other ponies' tricks, and most expand the sensitive-data surface the privacy design exists to avoid.

Added 2026-08-09 with the dose plan (#21): **no multi-injection dosing.** The AU product information's top Wegovy maintenance dose is 7.2 mg given as *three separate 2.4 mg injections*. That is not a dial position — it is a procedure, 222 clicks against a 74-click dial, and modelling it means counta reasoning about how many injections make a dose. We're a click counter, not a medical practitioner. The shipped preset stops at 2.4 mg, and a plan step is one dial of one pen.

## Dose plans (#21)

- A plan is **transcription, never suggestion.** counta ships one preset per listed product — the manufacturer's published escalation, labelled with the document and revision it came from — and it is never applied automatically: the setup select defaults to "No plan". counta does not generate, rank, smooth or comment on a ladder, and never tells a user theirs differs from the preset. `spec/i18n_spec.rb` enforces the wording half of that mechanically, with a positive control.
- **Jurisdiction is declared on the page.** Plan features follow the current **Australian** product information, and the setup card says so. This is not decoration: the AU PI allows five days to catch up a missed dose and says re-initiation "should be considered", while the US label says two days and "reinitiate". One paraphrase cannot be true of both — so counta paraphrases neither, states the user's own gap in days, and links the document it is calibrated to.
- **Ladders are not required to ascend.** Both labels describe deliberate down-steps (lowering to the previous dose while symptoms settle; dropping from 2.4 mg to 1.7 mg for maintenance, re-escalating later). A step with no dose count is an open-ended hold, which covers "delay escalation" too. Any validation that steps must increase would be a bug, not a tightening.
- **Numbers stop at the step boundary.** "Doses left" on a planned pen is doses left *at this amount*, and the tile names the amount. Forecasting past a step change would mean guessing what the next strength's pen holds.

## Tone

All copy descriptive, never prescriptive ("counter will show…", "you dialled…"), per the medical-device boundary noted in `data-privacy.md`. Footer disclaimer stays.
