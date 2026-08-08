// Dose plans (titration ladders) — issue #21.
//
// A plan is a sequence of `{units, doses}` steps that a user transcribes from
// their prescription (or from a product's published escalation, shipped as a
// citable preset). It lives inside the pen's own encrypted blob, copied per
// pen and linked across pens by a shared `plan.id`, so it survives a pen swap
// and leaves each archived pen holding the plan it was actually used under.
//
// Three properties this module exists to hold in one place:
//
//  1. **Steps are denominated in the medicine's units (mg/U), never clicks.**
//     Clicks are canonical for what HAPPENED (docs/architecture.md decision 3)
//     because they are what you did to one specific pen. A plan is INTENT, and
//     intent has to survive moving to a pen with a different clicks-per-unit
//     ratio — storing clicks would silently change the dose on a pen swap.
//     Callers convert with the active pen's own `clicksFor`.
//
//  2. **The current step is anchored on the dose COUNT, not the calendar.**
//     Both the AU and US labels write the schedule in weeks, for a weekly
//     drug, so weeks and doses are the same number for anyone dosing on time.
//     They diverge only when doses are missed — and that is exactly the case
//     where the labels stop saying "escalate" and start saying to consider
//     re-initiating lower. Counting doses therefore never advances anyone for
//     time they did not dose: the conservative reading is structural here, not
//     a rule that could have a bug. Week text is quoted from the source
//     document as `sourceLabel`, never computed from the calendar.
//
//  3. **This module builds no Date except inside `daysBetween`, and formats
//     nothing.** Dose ordinals are integers and dose dates are ISO
//     `YYYY-MM-DD` strings, which compare lexicographically — so almost every
//     derivation below is integer/string work with no timezone surface at all
//     (AGENTS.md §9.6). Callers add dates and copy.
//
// Consumers: the dose screen's step line and at-this-step run-out (#21), the
// next-dose forecast (#37), days-since-last-dose (#24), and ladder-aware
// calendar export (follow-up to #14). One derivation, several surfaces — the
// same seam #37 asks for so the calendar and the screen can't disagree.

/* ============ plan identity across pens ============ */

// Every pen carrying this plan, archived ones included: a plan routinely spans
// pens (a Wegovy pen holds four doses; a step is four doses), and the pen you
// took step 1 from is usually archived by the time you are on step 2.
export function planPens(pens, planId) {
  if (!planId) return [];
  return (pens ?? []).filter(p => p?.data?.plan?.id === planId);
}

// Concurrent pens can hold copies of the same plan that were edited on
// different devices. `rev` is the tiebreak the storage design specified: it is
// bumped on every edit, so the highest one is the newest. This is also what
// the 409 conflict handler in app.js uses, deliberately — one rule, one place
// it can be wrong.
export function currentPlan(pens, plan) {
  if (!plan?.id) return plan ?? null;
  return planPens(pens, plan.id)
    .map(p => p.data.plan)
    .reduce((best, copy) => ((copy.rev ?? 0) > (best.rev ?? 0) ? copy : best), plan);
}

/* ============ where the plan has got to ============ */

// Every dose recorded UNDER this plan, across every pen carrying it. One
// definition, because two would drift: a review of this file caught
// lastDoseDate applying only half of it, which let a dose predating the plan
// raise a missed-dose notice against a plan the user had only just started.
//
// Both filters do work. The plan-id filter keeps another medicine's pen from
// advancing this ladder (someone on Wegovy and insulin has both open at once).
// The date filter drops doses backdated to before the plan started. Note the
// date comparison is a plain string compare: ISO YYYY-MM-DD sorts
// lexicographically, so this needs no Date and has no timezone.
export function planDoses(plan, pens) {
  if (!plan?.id || !plan.startedOn) return [];
  return planPens(pens, plan.id)
    .flatMap(p => p.data.history ?? [])
    .filter(entry => entry.date >= plan.startedOn);
}

export function dosesTaken(plan, pens) {
  return planDoses(plan, pens).length;
}

// The most recent dose under this plan, or null when there hasn't been one.
// String max — again no Date, because ISO dates already sort correctly as text.
export function lastDoseDate(plan, pens) {
  return planDoses(plan, pens)
    .reduce((latest, entry) => (latest === null || entry.date > latest ? entry.date : latest), null);
}

// Which step the (0-based) Nth dose of the plan falls in.
//
// `doses: null` means an open-ended step — "stay here until I change it". It
// absorbs every later dose, which is what both a maintenance dose and a
// deliberate hold look like. Running off the end of a finite ladder holds at
// the last step rather than throwing: a plan the user has out-dosed is not an
// error state, it just has nothing further to say.
export function stepIndexFor(plan, doseIndex) {
  const steps = plan?.steps ?? [];
  if (!steps.length) return -1;
  let remaining = doseIndex;
  for (let i = 0; i < steps.length; i++) {
    const doses = steps[i].doses;
    if (doses == null || remaining < doses) return i;
    remaining -= doses;
  }
  return steps.length - 1;
}

// Everything the UI needs about the dose the user is about to record: which
// step it belongs to, how much of that step is left, and whether the step
// after it differs. Returns null when there is no usable plan, so every caller
// has one "no plan" branch rather than a scattering of optional chaining.
export function nextDoseStep(plan, pens) {
  const steps = plan?.steps ?? [];
  if (!steps.length) return null;

  const taken = dosesTaken(plan, pens);
  const index = stepIndexFor(plan, taken);
  const nextIndex = stepIndexFor(plan, taken + 1);

  // null = open-ended, and the UI says "ongoing" rather than a count.
  let dosesLeftAtStep = null;
  if (steps[index].doses != null) {
    let consumedBefore = taken;
    for (let i = 0; i < index; i++) consumedBefore -= steps[i].doses ?? 0;
    dosesLeftAtStep = Math.max(0, steps[index].doses - consumedBefore);
  }

  return {
    index,
    total: steps.length,
    step: steps[index],
    taken,
    dosesLeftAtStep,
    stepsUpNext: nextIndex !== index,
    nextStep: nextIndex === index ? null : steps[nextIndex]
  };
}

/* ============ what this pen can still deliver ============ */

// The doses this pen can still deliver **at the current step**, in order.
//
// It deliberately stops at the step boundary. Walking past it would mean
// converting the next step's mg through THIS pen's clicks-per-unit ratio, and
// for anyone following a published escalation the next step is a different pen
// with a different ratio — so the number would be a confident answer to a
// question we cannot answer until SKUs are modelled (issue #19). Truncating
// gives a number that is exactly true for every user instead of approximately
// true for some: on-label pen-swappers, people dialling a 2.4 mg pen down to a
// microdose, and people dialling a mid-strength pen down alike.
//
// Termination: the clicks budget is the real bound (each dose costs at least
// one click), the step boundary usually comes first, and `limit` is a runaway
// guard for a malformed plan — an open-ended step whose units round to zero
// clicks would otherwise spin. `!(clicks > 0)` also catches NaN.
export function schedule(plan, pens, { clicksFor, remainingClicks, limit = 2000 }) {
  const steps = plan?.steps ?? [];
  if (!steps.length) return [];

  const taken = dosesTaken(plan, pens);
  const stepIndex = stepIndexFor(plan, taken);
  const units = steps[stepIndex].units;

  const out = [];
  let left = remainingClicks;
  for (let n = 0; n < limit; n++) {
    const ordinal = taken + n;
    if (stepIndexFor(plan, ordinal) !== stepIndex) break;
    const clicks = clicksFor(units);
    if (!(clicks > 0) || clicks > left) break;
    left -= clicks;
    out.push({ ordinal, stepIndex, units, clicks });
  }
  return out;
}

/* ============ gaps ============ */

// Whole days between two local calendar dates.
//
// Both ends are built at local NOON. `Math.round` is what actually makes this
// DST-proof — an interval that gains or loses an hour still rounds to the
// right whole number of days — and noon is belt and braces for zones whose
// transition lands at midnight, where the midnight of a given date may not
// exist. Do not "simplify" the rounding to floor: across a spring-forward the
// interval is 167 hours, and floor turns seven days into six.
export function daysBetween(isoFrom, isoTo) {
  const at = iso => new Date(+iso.slice(0, 4), +iso.slice(5, 7) - 1, +iso.slice(8, 10), 12);
  return Math.round((at(isoTo) - at(isoFrom)) / 864e5);
}

// Scheduled doses skipped between the last recorded dose and today.
//
// freqDays 7: a gap of 7 is due-today (0 missed), 8 is a day late (0), 14 is
// one missed, 21 is two. The `- 1` is the dose that is due now rather than
// overdue. Fractional frequencies (3.5 = twice weekly) fall out of the same
// division.
//
// Note what this deliberately does NOT do: it does not decide whether a missed
// dose can still be taken. The AU product information says within five days,
// the US label says two, and they differ again on what several missed doses
// mean — so counta reports the gap and links the cited document rather than
// encoding a rule that would be wrong in one of them.
export function missedDosesSince(lastDoseISO, todayISO, freqDays) {
  if (!lastDoseISO || !(freqDays > 0)) return 0;
  return Math.max(0, Math.floor(daysBetween(lastDoseISO, todayISO) / freqDays) - 1);
}

export function missedDoses(plan, pens, todayISO, freqDays) {
  return missedDosesSince(lastDoseDate(plan, pens), todayISO, freqDays);
}

/* ============ validation ============ */

// The complete set of checks on a step. Returns a reason code, or null.
//
// There is deliberately NO check that steps ascend, and adding one would be a
// bug, not a tightening: both the AU and US product information describe
// stepping BACK DOWN — "lowering to the previous dose until symptoms have
// improved", and dropping from 2.4 mg to 1.7 mg for maintenance with the
// option to re-escalate later. A ladder that goes down, or down and then up
// again, is a first-class case. Someone will read this list, notice the
// missing ordering check, and want to "fix" it; this paragraph is why not.
//
// `maxDialClicks` is null on custom pens (the dial limit is unknown, not
// unlimited), so the dial check only applies when we actually know the limit.
export function planStepError(step, { clicksFor, maxDialClicks }) {
  if (!(step?.units > 0)) return "units";
  if (maxDialClicks != null && clicksFor(step.units) > maxDialClicks) return "dial";
  return null;
}

// Whether the pen in front of the user can physically dial the plan's next
// dose. Surfaced, never silently corrected — the plan is the user's
// transcription of their prescription and counta does not edit it.
export function stepUndeliverable(step, { clicksFor, maxDialClicks }) {
  return planStepError(step, { clicksFor, maxDialClicks }) === "dial";
}
