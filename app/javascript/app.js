// counta UI controller — behaviour ported from assets/counta-prototype.html
// (setup / dose / warnings / history), wrapped in the account/crypto flows the
// prototype stubbed out. The DEK lives only in this module's memory; a page
// reload drops it and the unlock screen re-derives it from a fresh passkey
// assertion.

import { api } from "api";
import { signup, signIn, addPasskey, recoverWithKit, signOut, deleteAccount } from "auth";
import { encryptPayload, decryptPayload } from "crypto";
import { PrfUnsupportedError } from "passkeys";
import { buildIcs } from "ics";
import { captureDosingTime, lastDoseTime, dosingTime } from "dosing_time";
import {
  currentPlan, nextDoseStep, dosesLeftAtStep, missedDoses, lastDoseDate,
  daysBetween, stepUndeliverable, planStepError, clicksForPen, isNewerRevision,
  reachableSteps, priorDosesFor, addDays, planDoses
} from "plan";
import { t, clicks, tNodes } from "i18n";

const $ = id => document.getElementById(id);
const PISTON_TRAVEL = 160;

// Fallback preset for "Something else…" pens (no product row).
const CUSTOM_PRESET = {
  id: "custom", name: "", strength: "", unit: "mg", decimals: 2,
  // Unused for custom pens — the counter style is asked at setup — but keep
  // the no-claim value here so any missed path fails safe.
  counter_style: "progress", capacity_units: null, capacity_ml: null,
  total_clicks: null, max_dial_clicks: Infinity, common_doses: [], default_freq_days: 7,
  theme: { "--c-body": "#8B9DC3", "--c-body-dark": "#6B7FA8", "--c-accent": "#DCE3F0",
           "--c-label": "#FFFFFF", "--c-text": "#1B3A6B", "--c-liquid": "#EAF4FB",
           "--c-button": "#8B9DC3", "--c-button-detail": "#5A6B8C" }
};

/* ============ state ============ */
let dek = null;          // Uint8Array while unlocked; null otherwise
let accountId = null;
let products = [];       // reference data from /api/products
let pens = [];           // [{id, data, updatedAt}] — data is the decrypted blob
let activePen = null;    // element of pens
let editingPen = null;   // pen being edited in setup, null = creating new
let doseClicks = 8;      // canonical dose selection, in clicks
let entryUnit = "units"; // 'units' | 'clicks'

const pen = () => activePen?.data;
const usedClicksOf = d => d.history.reduce((s, h) => s + h.clicks, 0);
const remainingClicksOf = d => Math.max(0, d.totalClicks - usedClicksOf(d));
const usedClicks = () => usedClicksOf(pen());
const remainingClicks = () => remainingClicksOf(pen());
// The active pen's plan, resolved against every pen carrying the same plan id
// so concurrent copies converge on the newest revision (see plan.js).
const activePlan = () => (pen()?.plan ? currentPlan(pens, pen().plan) : null);
// What the next dose will be, per the plan — null when the pen has no plan.
const planStep = () => nextDoseStep(activePlan(), pens);

// TWO different questions, and they must not share a function. The first cut
// of the dose plan collapsed them, which quietly truncated the calendar export
// to the current step and made a full pen refuse to export at all.
//
//   remainingDoses()  — "how many doses of the size currently dialled does
//                        this pen physically hold". Pen capacity. What the
//                        calendar export, the expiry warning and the
//                        running-low warnings have always meant, plan or no
//                        plan. Unchanged from before plans existed.
//
//   planDosesLeft()   — "how many doses the plan has left at this step, on
//                        this pen". Plan shaped, stops at the step boundary,
//                        and feeds exactly one thing: the doses tile.
//
// doseClicks is already clamped to the dial and to what's left (clampDose), so
// it is by construction a size this pen can deliver — which is what makes
// remainingDoses honest even when the plan asks for something it can't.
const remainingDoses = () => (doseClicks > 0 ? Math.floor(remainingClicks() / doseClicks) : 0);
const planDosesLeft = () => {
  const p = activePlan();
  return p ? dosesLeftAtStep(p, pens, { clicksFor, remainingClicks: remainingClicks() }) : null;
};
const unitsPerClick = () => pen().capUnits / pen().totalClicks;
// Trim trailing zeros, but only after the decimal point: "10.00" -> "10",
// "1.70" -> "1.7", "0.26" -> "0.26". The original single-zero strip left
// whole numbers reading "10.0".
const fmtUnits = (v, decimals) => decimals
  ? (Math.round(v * 100) / 100).toFixed(2).replace(/\.?0+$/, "")
  : Math.round(v).toString();
const fmtU = v => fmtUnits(v, pen().decimals);
const clicksFor = u => clicksForPen(u, pen());
const unitsForClicks = c => c * unitsPerClick();
// Local-calendar date. Never toISOString() — that converts to UTC and lands a
// day early/late for anyone not on UTC (AGENTS.md §9.6).
const isoDate = d =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const todayISO = () => isoDate(new Date());
const announce = msg => { $("sr-live").textContent = msg; };
// Escape anything interpolated into innerHTML. Product fields (unit, name,
// theme) come from the server's product table, so a write-capable DB attacker
// could otherwise inject script into an unlocked session and read the DEK
// straight out of this module's scope.
const esc = s => String(s).replace(/[&<>"']/g, c =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
// Same threat as esc(), different sink: a plan preset's citation URL comes
// from the server's product table, and an href is a script sink
// (`javascript:…`). Only ever render an http(s) link.
const safeHref = url => (/^https?:\/\//i.test(url ?? "") ? url : null);

/* ============ screens ============ */
const SCREENS = [ "landing-screen", "unlock-screen", "recovery-screen", "app-screen", "account-screen" ];
function show(id) {
  SCREENS.forEach(s => { $(s).hidden = s !== id; });
  const inApp = id === "app-screen" || id === "account-screen";
  $("chip").hidden = !inApp;
  $("account-btn").hidden = !inApp;
}
function showError(elId, err) {
  const el = $(elId);
  el.textContent = err instanceof Error ? err.message : String(err);
  el.hidden = false;
}
function clearError(elId) { $(elId).hidden = true; }

/* ============ persistence (encrypted blobs) ============ */
// Archive state is server-held (pens.archived_at) — the client sends the
// intent and renders the timestamps it gets back. It does no date arithmetic:
// the retention deadline is derived server-side with ActiveSupport.
function adoptRow(p, row) {
  p.id = row.id;
  p.updatedAt = row.updated_at;
  p.archivedAt = row.archived_at;
  p.purgeAfter = row.purge_after;
}

// Union two dose histories. Doses are append-only per pen, so a merge is a
// union — never a choice between versions.
//
// Entries written before dose ids existed have no identity beyond their
// contents, so two identical doses on the same date share a key. Deduping by
// key would then silently delete one of them even when BOTH sides agree it
// happened, so the merge is a multiset: for each key, keep whichever side has
// more occurrences. That preserves genuine repeats while still collapsing the
// same dose seen twice.
function mergeHistory(mine, theirs) {
  const key = e => e.id || `legacy:${e.date}:${e.clicks}`;
  const group = list => list.reduce((map, entry) => {
    const k = key(entry);
    if (!map.has(k)) map.set(k, []);
    map.get(k).push(entry);
    return map;
  }, new Map());

  const ours = group(mine), theirsByKey = group(theirs);
  const merged = [];
  for (const k of new Set([ ...ours.keys(), ...theirsByKey.keys() ])) {
    const a = ours.get(k) ?? [], b = theirsByKey.get(k) ?? [];
    merged.push(...(a.length >= b.length ? a : b));
  }
  return byDate(merged);
}

async function persistPen(p, opts = {}) {
  // Whether the CALLER is deciding the archive state matters on retry: an
  // ordinary dose save must not carry its stale idea of it (see below).
  const archiveIsIntentional = "archived" in opts;
  let archived = archiveIsIntentional ? opts.archived : p.archivedAt != null;

  if (!p.id) {
    adoptRow(p, await api("/api/pens", {
      method: "POST", body: { blob: await encryptPayload(dek, p.data), archived }
    }));
    return;
  }

  const write = async () => api(`/api/pens/${p.id}`, {
    method: "PUT",
    body: {
      blob: await encryptPayload(dek, p.data),
      archived,
      // What this write is based on. The server rejects it if the stored row
      // has moved on, rather than letting a stale tab overwrite a whole dose
      // history (issue #2).
      expected_updated_at: p.updatedAt
    }
  });

  try {
    adoptRow(p, await write());
  } catch (e) {
    if (e.status !== 409) throw e;
    // Another device got there first. Merge its history with ours and retry
    // once against the version it wrote — a second conflict means something
    // is writing continuously, and failing loudly beats looping.
    //
    // Snapshot first: if the retry also fails, the caller's rollback runs
    // against state we've already rewritten, and it would undo the wrong
    // thing. On failure this leaves the pen exactly as the caller handed it
    // over, so their rollback means what it says.
    const snapshot = {
      history: p.data.history, updatedAt: p.updatedAt, archived,
      calendarUid: p.data.calendarUid, calendarSequence: p.data.calendarSequence,
      plan: p.data.plan
    };
    try {
      const theirs = await decryptPayload(dek, e.body.blob);
      p.data.history = mergeHistory(p.data.history || [], theirs.history || []);
      // History's union-merge doesn't generalise to every blob field: a
      // non-append-only field (one device's write means to REPLACE a value,
      // not add to a set) needs its own policy here, or the retry below
      // silently overwrites whatever the winning device stored with this
      // device's stale copy. calendarUid/calendarSequence (#14) are the
      // first of these — issue #21's plan.rev will join this list, and
      // needs the same treatment.
      //
      // calendarUid: theirs already persisted first, and may already be
      // live in a third-party calendar under it — theirs always wins over
      // a locally-minted guess.
      if (theirs.calendarUid) p.data.calendarUid = theirs.calendarUid;
      // calendarSequence: RFC 5545 requires it to only grow. A write that
      // means to bump it (an export, opts.bumpCalendarSequence) must land
      // STRICTLY ABOVE theirs, not above this device's now-stale bump —
      // otherwise the loser of the race walks the sequence backwards and
      // calendar clients ignore the winner's already-exported update as
      // stale. A write that doesn't intend to touch it just adopts theirs,
      // same as archived below.
      if (opts.bumpCalendarSequence) {
        p.data.calendarSequence = (theirs.calendarSequence || 0) + 1;
      } else if (theirs.calendarSequence != null) {
        p.data.calendarSequence = theirs.calendarSequence;
      }
      // plan (#21): also not append-only — an edit REPLACES the steps, so
      // there is nothing to union. Same two policies as calendarSequence:
      //   - a write that doesn't mean to touch the plan (logging a dose,
      //     archiving, exporting) adopts theirs, or it would push its own
      //     stale copy over the other device's edit;
      //   - a write that DOES mean to (opts.planIntent — only savePenForm)
      //     keeps ours unless theirs is strictly newer by `rev`, which is the
      //     entire reason `rev` exists.
      // Known edge, chosen deliberately: removing a plan here while another
      // device edits it lets the edit win, because a removal has no rev to
      // compare. That errs toward keeping data the user typed, and removing
      // again works — the opposite default would silently discard their edit.
      // Same comparator plan.js uses everywhere else, so "which copy is newer"
      // has one definition. Note the asymmetry it introduces here and why it
      // is wanted: a local plan of null scores 0, so a concurrent edit wins
      // over a removal, per the note above.
      if (opts.planIntent) {
        if (isNewerRevision(theirs.plan, p.data.plan)) p.data.plan = theirs.plan;
      } else {
        p.data.plan = theirs.plan ?? null;
      }
      p.updatedAt = e.body.updated_at;
      // If the other device archived the pen, a dose save must not undo that:
      // this write never intended to change archive state, so adopt theirs.
      if (!archiveIsIntentional) archived = e.body.archived_at != null;
      adoptRow(p, await write());
    } catch (retryError) {
      p.data.history = snapshot.history;
      p.data.calendarUid = snapshot.calendarUid;
      p.data.calendarSequence = snapshot.calendarSequence;
      p.data.plan = snapshot.plan;
      p.updatedAt = snapshot.updatedAt;
      archived = snapshot.archived;
      throw retryError;
    }
  }
}

async function loadPens() {
  const rows = await api("/api/pens");
  pens = [];
  // Retention is applied server-side by PenPurgeJob — nothing to prune here.
  for (const row of rows) {
    const p = { data: await decryptPayload(dek, row.blob) };
    adoptRow(p, row);
    pens.push(p);
  }
  activePen = pens.find(p => !p.archivedAt) || pens[0] || null;
}

/* ============ app entry after DEK is in memory ============ */
async function loadApp() {
  if (!products.length) products = await api("/api/products");
  await loadPens();
  show("app-screen");
  if (activePen) {
    enterDoseMode();
  } else {
    buildProductSelect();
    fillSetupForm(products[0].id);
    enterSetup(false);
  }
}

/* ============ setup mode (ported) ============ */
function productByKey(key) {
  return key === "custom" ? CUSTOM_PRESET : products.find(p => p.id === key);
}

function buildProductSelect() {
  const sel = $("f-product");
  sel.innerHTML = "";
  products.forEach(p => sel.append(new Option(`${p.name} ${p.strength} (${p.capacity_label})`, p.id)));
  sel.append(new Option(t("product_other"), "custom"));
}

function fillSetupForm(key) {
  const p = productByKey(key);
  $("f-product").value = key;
  $("custom-name-wrap").hidden = key !== "custom";
  const cap = $("f-capacity");
  cap.innerHTML = "";
  if (p.capacity_label) cap.append(new Option(p.capacity_label, "0"));
  cap.append(new Option(t("setup.capacity_custom"), "custom"));
  cap.value = p.capacity_label ? "0" : "custom";
  $("custom-cap-wrap").hidden = cap.value !== "custom";
  $("f-clicks").value = p.total_clicks ?? "";
  $("clicks-hint").textContent = p.capacity_label
    ? t("setup.total_clicks_hint_preset", {
        clicks: p.total_clicks, name: p.name, capacity: p.capacity_label })
    : t("setup.total_clicks_hint_custom");
  $("f-freq").value = String(p.default_freq_days);
  buildPlanSelect(key);
}

/* ============ dose plan: the setup form (issue #21) ============ */
// Presets are public reference data hanging off the product row — a
// transcription aid for copying a published schedule accurately, nothing more.
// counta never applies one: the select defaults to "no plan", and the app
// neither suggests a ladder nor comments on the one someone chose.
const planPresetsFor = key => productByKey(key)?.plan_presets ?? [];

// A plan belongs to the person and their medicine, not to one pen — a Wegovy
// pen holds four doses and a step is four doses, so a plan outlives every pen
// it is delivered from. A new pen for the same product therefore offers to
// continue the plan already in progress.
//
// Archived pens count as donors on purpose: the usual sequence is "pen runs
// out, archive it, add the next one", so skipping them would miss exactly the
// case this exists for. Matching is by productKey; continuing across the
// different SKUs of one product (Wegovy ships a separate pen per strength)
// needs SKUs modelled first (issue #19).
function donorPlan(productKey) {
  // "Something else…" is not a medicine, it is the absence of one: every
  // unlisted pen shares the productKey "custom", so matching on it would offer
  // a custom insulin pen the mg ladder from a custom Wegovy pen. There is no
  // field that says two unlisted pens hold the same drug, so counta doesn't
  // guess — an unlisted pen's plan is transcribed again by hand.
  if (!productKey || productKey === "custom") return null;

  const plans = pens
    .filter(p => p !== editingPen && p.data?.plan?.id && p.data.productKey === productKey)
    .map(p => p.data.plan);
  if (!plans.length) return null;

  // `rev` counts edits WITHIN one plan, so a plain max-rev across candidates
  // would prefer a long-running plan on rev 9 over the one started yesterday
  // that replaced it. Group by id first: pick the plan the person is actually
  // on — most recent dose, then most recent start — and only then use rev to
  // choose between concurrent copies of that same plan.
  const byId = new Map();
  for (const plan of plans) {
    const best = byId.get(plan.id);
    if (!best || isNewerRevision(plan, best)) byId.set(plan.id, plan);
  }
  // Compared field by field, NOT as one joined string: a plan with no doses
  // yet contributes an empty first field, and any separator character that
  // sorts above a digit would then rank it above a plan dosed yesterday.
  const key = plan => [ lastDoseDate(plan, pens) ?? "", plan.startedOn ?? "" ];
  return [ ...byId.values() ].reduce((best, plan) => {
    const a = key(plan), b = key(best);
    return (a[0] === b[0] ? a[1] > b[1] : a[0] > b[0]) ? plan : best;
  });
}

// Default start date for a newly transcribed plan: the pen's earliest recorded
// dose if it has any, otherwise today. A local calendar date throughout —
// never toISOString() (AGENTS.md §9.6).
//
// For someone joining partway up the ladder it is always today, because the
// date means "when counta starts counting", not "when the journey began". The
// doses before that are carried as `priorDoses`, not as a backdated window.
function planStartDefault() {
  if (priorDosesFromForm() > 0) return todayISO();
  const history = editingPen?.data?.history ?? [];
  return history.length ? byDate(history)[0].date : todayISO();
}

// The steps of the preset currently selected, or null when the form isn't
// transcribing one. Shared by the progress control and the plan it builds so
// the two can't disagree about the ladder.
function selectedPresetSteps() {
  const sel = $("f-plan").value;
  if (!sel.startsWith("preset:")) return null;
  const preset = planPresetsFor($("f-product").value).find(p => `preset:${p.key}` === sel);
  return preset ? preset.steps.map(s => ({
    units: s.units,
    doses: s.doses ?? null,
    // Quoted from the source document's own table, so week wording can be
    // displayed without ever computing a week number from the calendar.
    sourceLabel: s.source_label ?? null
  })) : null;
}

// Doses taken before counta started counting, from the two progress controls.
//
// The question asked is "which amount are you taking now" plus "how many have
// you already had at it", both of which are facts the person already knows.
// The alternative framing — what their NEXT dose will be — makes them work out
// whether they are due to step up, which is the one thing this feature exists
// to work out for them.
function priorDosesFromForm() {
  const steps = selectedPresetSteps();
  const index = $("f-plan-progress").value;
  if (!steps || index === "") return 0;
  return priorDosesFor(steps, parseInt(index, 10), parseInt($("f-plan-prior").value, 10) || 0);
}

// Someone can't have had more doses at an amount than the ladder has at it.
// Refused rather than clamped: silently reducing a number the user typed about
// their own medication would move them to a step they didn't choose.
function planProgressError() {
  const steps = selectedPresetSteps();
  const index = $("f-plan-progress").value;
  if (!steps || index === "") return null;
  const step = steps[parseInt(index, 10)];
  const atStep = parseInt($("f-plan-prior").value, 10) || 0;
  if (atStep < 0) return t("errors.plan_prior_negative");
  if (step?.doses != null && atStep > step.doses) {
    return t("errors.plan_prior_range", {
      units: fmtUnits(step.units, productByKey($("f-product").value).decimals),
      unit: productByKey($("f-product").value).unit,
      count: step.doses
    });
  }
  return null;
}

function buildPlanSelect(key) {
  const sel = $("f-plan");
  const presets = planPresetsFor(key);
  const existing = editingPen?.data?.plan ?? null;
  const donor = existing ? null : donorPlan(key);

  sel.innerHTML = "";
  if (existing) sel.append(new Option(t("plan.option_keep", { label: existing.label }), "keep"));
  sel.append(new Option(t("plan.option_none"), "none"));
  if (donor) sel.append(new Option(t("plan.option_continue", { label: donor.label }), `continue:${donor.id}`));
  presets.forEach(preset =>
    sel.append(new Option(t("plan.option_preset", { label: preset.label, source: preset.source.label }),
      `preset:${preset.key}`)));
  sel.value = existing ? "keep" : "none";
  // Cleared rather than left alone: the input keeps its value across a switch
  // to another pen, and syncPlanUi only fills a blank one — so without this a
  // second pen's new plan would silently inherit the first pen's start date.
  $("f-plan-start").value = "";
  delete $("f-plan-start").dataset.touched;
  $("f-plan-progress").value = "";
  $("f-plan-prior").value = "0";

  // Nothing to offer, nothing to show: an unlisted pen with no published
  // schedule and no plan in progress gets no plan section at all rather than
  // an empty control implying a feature that isn't reachable from here.
  $("plan-wrap").hidden = !presets.length && !existing && !donor;
  syncPlanUi();
}

// The plan this form would save. Called both to preview and to save, so the
// summary a user reads is produced by the same code that stores it.
function planFromSetupForm() {
  const sel = $("f-plan").value;
  const existing = editingPen?.data?.plan ?? null;

  // Carried over exactly like history / registrationIds / calendarUid:
  // savePenForm rebuilds the WHOLE blob on every save, including a save that
  // only fixes a typo'd batch number. Without this branch, correcting a batch
  // number silently deletes the ladder — the same defect shape as issue #1,
  // and the reason issue #18 wants most of this form frozen.
  if (sel === "keep") return existing;
  if (sel === "none") return null;

  if (sel.startsWith("continue:")) {
    const donor = donorPlan($("f-product").value);
    // Same id AND same rev: continuing isn't an edit, it's the same version of
    // the same plan arriving on the next pen.
    return donor && `continue:${donor.id}` === sel ? donor : existing;
  }

  const preset = planPresetsFor($("f-product").value).find(p => `preset:${p.key}` === sel);
  if (!preset) return existing;
  return {
    id: crypto.randomUUID(),
    // Starts above whatever it replaces so the 409 handler's higher-rev-wins
    // rule sees this as the newer version.
    rev: (existing?.rev ?? 0) + 1,
    presetKey: preset.key,
    label: preset.label,
    // The citation travels with the plan rather than being looked up from the
    // product row at render time, so an archived pen keeps the document its
    // plan was actually transcribed from even after the row is revised.
    source: preset.source,
    startedOn: $("f-plan-start").value || planStartDefault(),
    // Doses taken before counta existed for this person. On the PLAN, never on
    // a pen: they were often taken on a starter pen, on tablets, or on a pen
    // counta was never told about, so writing them into some pen's dose log
    // would be recording events that pen never saw. Travels verbatim with the
    // plan onto the next pen, where it is added once rather than per pen.
    priorDoses: priorDosesFromForm(),
    steps: selectedPresetSteps()
  };
}

function planSourceLink(source) {
  const href = safeHref(source?.url);
  if (!href) return document.createTextNode(source?.label ?? "");
  const a = document.createElement("a");
  a.href = href;
  a.target = "_blank";
  a.rel = "noopener noreferrer";
  a.textContent = source.label;
  return a;
}

function syncPlanUi() {
  const creating = $("f-plan").value.startsWith("preset:");
  $("plan-progress-wrap").hidden = !creating;
  buildPlanProgress();
  $("plan-start-wrap").hidden = !creating;
  // Recomputed rather than filled-once, because choosing a position partway up
  // the ladder changes what the start date means: today, not the journey's
  // beginning. A date the user has actually edited is left alone.
  if (creating && !$("f-plan-start").dataset.touched) {
    $("f-plan-start").value = planStartDefault();
  }

  const plan = planFromSetupForm();
  const list = $("plan-summary");
  list.innerHTML = "";
  if (plan?.steps?.length) {
    const p = productByKey($("f-product").value);
    plan.steps.forEach((step, i) => {
      const li = document.createElement("li");
      const label = document.createElement("span");
      label.textContent = step.sourceLabel
        || t("plan.step_number", { number: i + 1, total: plan.steps.length });
      const amount = document.createElement("span");
      amount.textContent = t("plan.summary_amount", {
        units: fmtUnits(step.units, p.decimals),
        unit: p.unit,
        doses: step.doses == null ? t("plan.ongoing") : t("plan.doses_count", { count: step.doses })
      });
      li.append(label, amount);
      list.append(li);
    });
  }
  $("plan-summary").hidden = !plan?.steps?.length;

  $("plan-setup-source").hidden = !plan?.source;
  if (plan?.source) {
    $("plan-setup-source").replaceChildren(
      ...tNodes("plan.source_line", { source: planSourceLink(plan.source) }));
  }

  // Say back where this lands, in the app's own words. The whole risk in
  // asking "how many have you had at this amount" is the reader being a dose
  // out either way, and a plain restatement of the answer is the cheapest way
  // to make that visible before it is saved rather than after.
  const position = plan && priorDosesFromForm() > 0 ? nextDoseStep(plan, []) : null;
  $("plan-position").hidden = !position;
  if (position) {
    const p = productByKey($("f-product").value);
    $("plan-position").textContent = t("plan.position", {
      units: fmtUnits(position.step.units, p.decimals),
      unit: p.unit,
      remaining: position.complete
        ? t("plan.complete")
        : position.dosesLeftAtStep == null
          ? t("plan.ongoing")
          : t("plan.doses_left_at_step", { count: position.dosesLeftAtStep })
    });
  }
}

// Where in the ladder someone already is. Only the steps they could actually
// be on: an open-ended step never ends, so nothing after one is reachable.
function buildPlanProgress() {
  const steps = selectedPresetSteps();
  const sel = $("f-plan-progress");
  const p = productByKey($("f-product").value);
  const previous = sel.value;

  sel.innerHTML = "";
  sel.append(new Option(t("plan.progress_starting"), ""));
  if (steps) {
    reachableSteps(steps).forEach((step, i) =>
      sel.append(new Option(
        t("plan.progress_at", { units: fmtUnits(step.units, p.decimals), unit: p.unit }), String(i))));
  }
  // Preserve the choice across an unrelated re-render, but never carry it onto
  // a different ladder where the index would mean a different amount.
  sel.value = [ ...sel.options ].some(o => o.value === previous) ? previous : "";

  const chosen = sel.value === "" ? null : steps?.[parseInt(sel.value, 10)];
  $("plan-prior-wrap").hidden = !chosen;
  if (!chosen) {
    $("f-plan-prior").value = "0";
    return;
  }
  // The label names the amount, so a screen reader user hears which dose the
  // number belongs to rather than a bare "how many".
  $("plan-prior-label").textContent = t("plan.prior_label", {
    units: fmtUnits(chosen.units, p.decimals), unit: p.unit
  });
  if (chosen.doses == null) $("f-plan-prior").removeAttribute("max");
  else $("f-plan-prior").max = String(chosen.doses);
}

// Every check a plan gets, and there are deliberately only two. See
// plan.js#planStepError for why an "ascending steps" check must never join
// them. Conversion uses the ratio of the pen being SAVED, not the pen
// currently on screen — during setup those can be different pens.
function planFormError(plan, penShape) {
  if (!plan) return null;
  const { capUnits, totalClicks, maxDialClicks, unit, decimals } = penShape;
  // A plan with no steps is not "no plan" — it is a plan that can never say
  // what the next dose is, and the dose screen has nothing to render for it.
  // Refusing it here is the only place the state is stoppable from the UI;
  // renderPlan also guards, because a plan adopted from another device in a
  // 409 merge never passes through this function.
  if (!plan.steps?.length) return t("errors.plan_empty");

  const clicksForForm = u => clicksForPen(u, { capUnits, totalClicks });
  const perClick = capUnits / totalClicks;

  // A non-positive amount is malformed whatever pen it lands on.
  if (plan.steps.some(step => !(step?.units > 0))) return t("errors.plan_units");

  // The dial checks apply to the step THIS pen is about to deliver, and only
  // that one. A later step legitimately belongs to a different pen — a
  // published escalation ships a separate pen per strength — so checking the
  // whole ladder against this pen's dial would refuse the most ordinary real
  // plan there is. Drift into an undeliverable step later is reported on the
  // dose screen instead (renderPlan), never silently corrected.
  const step = nextDoseStep(plan, pens)?.step;
  const error = step && planStepError(step, { clicksFor: clicksForForm, maxDialClicks });
  if (error === "dial") {
    return t("errors.plan_dial", {
      units: fmtUnits(step.units, decimals), unit,
      max: fmtUnits(maxDialClicks * perClick, decimals)
    });
  }
  if (error === "tiny") {
    return t("errors.plan_tiny", { units: fmtUnits(step.units, decimals), unit });
  }
  return null;
}

function enterSetup(fromDose) {
  $("setup-card").hidden = false;
  $("dose-card").hidden = true;
  $("cancel-setup").hidden = !fromDose;
  // Archive/trash live on the edit screen ("settings"), never on new-pen setup.
  previewSetupPen();
  $("archive-pen-edit").hidden = !editingPen || !!editingPen.archivedAt;
  $("trash-pen-edit").hidden = !editingPen;
  buildSwitcher();
  showBack(true);
  $("f-product").focus({ preventScroll: true });
}

async function savePenForm() {
  const key = $("f-product").value, p = productByKey(key);
  const capSel = $("f-capacity").value;
  let capUnits, capMl, unitName = p.unit;
  if (capSel === "custom") {
    capUnits = parseFloat($("f-cap-units").value) || 0;
    capMl = null;
    if (key === "custom") unitName = ($("f-cap-unitname").value || "mg").trim();
  } else {
    capUnits = p.capacity_units;
    capMl = p.capacity_ml;
  }
  const totalClicks = parseInt($("f-clicks").value, 10);
  if (!capUnits || !totalClicks) {
    alert(t("errors.capacity_required"));
    return;
  }
  const progressError = planProgressError();
  if (progressError) {
    alert(progressError);
    return;
  }
  const plan = planFromSetupForm();
  const planError = planFormError(plan, {
    capUnits, totalClicks, maxDialClicks: p.max_dial_clicks ?? null,
    unit: unitName, decimals: p.decimals
  });
  if (planError) {
    alert(planError);
    return;
  }
  // Spread the existing blob first, then override only what this form owns.
  //
  // This function rebuilds the entire blob on every save, including a save
  // that only fixes a typo'd batch number — so under the old shape any field
  // the literal forgot to name was silently deleted by an unrelated edit. That
  // class has now been patched three times (the capacity reset in #1,
  // calendarUid/calendarSequence in #14, plan here). Spreading makes survival
  // the default rather than something each new field has to remember, so the
  // next field added to the blob is safe by construction.
  //
  // The defaults below still matter: a NEW pen has nothing to spread from, and
  // they are what a first save writes.
  const data = {
    history: [], registrationIds: [], calendarUid: null, calendarSequence: 0,
    ...(editingPen?.data ?? {}),

    // Everything from here down is owned by this form and always overwritten.
    v: 1,
    productKey: key,
    name: key === "custom" ? ($("f-name").value || "My pen") : p.name,
    strength: key === "custom" ? "" : p.strength,
    unit: unitName, decimals: p.decimals,
    // Listed products carry a verified counter_style; for an unlisted pen only
    // the user can say, so it's asked at setup (defaulting to the wording that
    // makes no claim about the window).
    counterStyle: key === "custom" ? $("f-counter-style").value : p.counter_style,
    capUnits, capMl, totalClicks,
    batch: $("f-batch").value.trim(), expiry: $("f-expiry").value,
    freqDays: parseFloat($("f-freq").value),
    // Never Infinity here: the blob is JSON, and JSON.stringify(Infinity) is
    // "null", which read back as 0 through Math.min and silently clamped every
    // dose to 1 click. null means "no dial limit known" — see clampDose.
    maxDialClicks: p.max_dial_clicks ?? null,
    common: p.common_doses, theme: p.theme,
    // The plan IS form-owned — the select decides it, and its "keep" branch is
    // what makes an unrelated edit preserve the ladder rather than the spread
    // above (which would also preserve it, but silently, and would keep a plan
    // the user had just chosen to remove).
    plan
  };

  // Don't mutate local state until the server has it: a failed save used to
  // leave the UI (and the switcher) showing a pen the server never received.
  const target = editingPen ?? { id: null, data: null };
  const previousData = target.data;
  target.data = data;
  const isNew = !editingPen;
  if (isNew) pens.push(target);
  try {
    // planIntent: this is the ONE write that means to decide the plan, so on a
    // 409 it keeps its own copy unless the other device's is newer by rev.
    // Every other write adopts theirs (see persistPen).
    await persistPen(target, { planIntent: true });
  } catch (e) {
    if (isNew) pens = pens.filter(p => p !== target);
    else target.data = previousData;
    console.error(e);
    alert(t("errors.save_pen"));
    return;
  }
  activePen = target;
  editingPen = null;
  enterDoseMode();
  announce(t("status.pen_saved"));
}

// The header chip is the pen switcher: pens in use, plus the add-a-pen entry
// (docs/design-notes.md "Multi-pen"). Archived pens are deliberately absent —
// they aren't switchable daily-use context; they live in the account panel.
function penLabel(p) {
  const d = p.data;
  const pct = d.totalClicks ? Math.round(remainingClicksOf(d) / d.totalClicks * 100) : 100;
  return d.strength
    ? t("pen.switcher", { name: d.name, strength: d.strength, percent: pct })
    : t("pen.switcher_no_strength", { name: d.name, percent: pct });
}

function activePens() {
  return pens.filter(p => !p.archivedAt);
}

function buildSwitcher() {
  const sel = $("chip");
  sel.innerHTML = "";
  // Viewing an archived pen isn't a switchable state, so it shows as a
  // disabled marker rather than a listed option.
  if (activePen?.archivedAt) {
    const marker = new Option(t("pen.archived_suffix", { name: activePen.data.name }), "__archived__");
    marker.disabled = true;
    sel.append(marker);
  }
  activePens().forEach(p => sel.append(new Option(penLabel(p), p.id)));
  sel.append(new Option(t("pen.add"), "__add__"));
  sel.value = activePen?.archivedAt ? "__archived__" : activePen?.id;
  sel.hidden = pens.length === 0;
}

// Calendar-date helpers. `new Date("2026-08-31")` parses as UTC midnight while
// `new Date(y, m, d)` is LOCAL midnight — mixing the two made a pen read as
// expired a day early anywhere east of UTC. Every comparison below is
// local-midnight to local-midnight.
const localMidnight = iso =>
  new Date(+iso.slice(0, 4), +iso.slice(5, 7) - 1, +iso.slice(8, 10) || 1);
const startOfToday = () => { const d = new Date(); d.setHours(0, 0, 0, 0); return d; };
// Dose entries are appended in the order they're logged, which isn't date
// order once anything is backdated. Anything that means "most recent dose"
// must sort first.
const byDate = history => [ ...history ].sort((a, b) => a.date.localeCompare(b.date));
// Month + year in the viewer's locale — never MM/YYYY, whose field order and
// separator differ by locale and reads as ambiguous to half the world.
const monthYear = expiry =>
  new Date(+expiry.slice(0, 4), +expiry.slice(5, 7) - 1, 1)
    .toLocaleDateString(undefined, { month: "short", year: "numeric" });
const unitsLeftLabel = (d, rc) => d.capMl
  ? t("stats.units_left_ml", { unit: d.unit, ml: (d.capMl * rc / d.totalClicks).toFixed(2) })
  : t("stats.units_left", { unit: d.unit });
// Last day of the pen's expiry month, local midnight.
const expiryEnd = d => new Date(+d.expiry.slice(0, 4), +d.expiry.slice(5, 7), 0);

function isExpired(d) {
  if (!d.expiry) return false;
  return expiryEnd(d) < startOfToday();
}

// Both dates come from the server as UTC ISO8601; the browser's only job is
// to render them in the viewer's local zone.
const localDate = iso =>
  new Date(iso).toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });

// <time datetime> carries the machine-readable instant alongside the
// human-readable local rendering — better semantics for assistive tech, and
// it gives tests something to assert that doesn't shift with the viewer's
// locale.
function timeEl(iso) {
  const el = document.createElement("time");
  el.dateTime = iso;
  el.textContent = localDate(iso);
  return el;
}

function renderArchivedNote(p) {
  $("archived-note-text").replaceChildren(...tNodes("archived.note", {
    archived_on: timeEl(p.archivedAt),
    purge_after: timeEl(p.purgeAfter)
  }));
}

function enterDoseMode() {
  const d = pen();
  $("setup-card").hidden = true;
  $("dose-card").hidden = false;
  buildSwitcher();
  showBack(false);
  renderHistory();

  const archived = !!activePen.archivedAt;
  $("dose-entry").hidden = archived;
  $("archived-note").hidden = !archived;
  $("unarchive-pen").hidden = !archived;
  $("export-ics").hidden = archived;
  $("edit-pen").hidden = archived;
  $("trash-pen").hidden = !archived;
  $("archive-pen").hidden = true;
  if (archived) {
    renderArchivedNote(activePen);
    paintPen();
  } else {
    doseClicks = d.common.length ? clicksFor(d.common[0]) : Math.min(8, d.totalClicks);
    syncDialToPlan();
    $("f-date").value = todayISO();
    buildChips();
    renderDose();
  }
}

// A pen with a plan shows the plan's next dose already dialled — the feature
// felt without a tap. This runs when the pen is opened AND after each dose is
// recorded, because recording the last dose of a step changes what the next
// dose is: leaving the dial on the old amount would invite dialling the wrong
// one, which is the blast radius docs/architecture.md decision 3 describes.
function syncDialToPlan() {
  const step = planStep();
  if (step) doseClicks = clicksFor(step.step.units);
}

async function setArchived(flag) {
  try {
    await persistPen(activePen, { archived: flag });
  } catch (e) {
    console.error(e);
    alert(t("errors.update_pen"));
    return;
  }
  editingPen = null;
  // Stay on the pen: seeing its archived state (and the retention line) is
  // the confirmation that the action landed.
  enterDoseMode();
  announce(t(flag ? "status.pen_archived" : "status.pen_unarchived"));
}

/* ============ pen svg (ported; hooks per counta-pen.svg header) ============ */
const svg = () => $("pen-svg");
// Applies a product's colours to the graphic. Separate from paintPen because
// setup needs to preview a product before any pen exists — and because the
// default theme can no longer ride in an inline style attribute: the CSP has
// no 'unsafe-inline', so those attributes are dropped and every var() fell
// back to nothing, rendering the pen black (issue #17).
function paintTheme(theme) {
  if (!theme) return;
  const s = svg();
  for (const [ k, v ] of Object.entries(theme)) s.style.setProperty(k, v);
}

// Previews the product currently selected in the setup form.
function previewSetupPen() {
  const key = $("f-product").value;
  const p = productByKey(key);
  if (!p) return; // products not loaded yet
  paintTheme(p.theme);
  const s = svg();
  s.querySelector("#product-name").textContent =
    key === "custom" ? ($("f-name").value || t("pen.default_name")) : p.name;
  s.querySelector("#product-strength").textContent = p.strength || "";
}

function paintPen() {
  const d = pen();
  if (!d) return;
  const s = svg();
  paintTheme(d.theme);
  const n = s.querySelector("#product-name");
  n.textContent = d.name || t("pen.default_name");
  n.removeAttribute("textLength");
  if (n.getComputedTextLength() > 118) {
    n.setAttribute("textLength", 118);
    n.setAttribute("lengthAdjust", "spacingAndGlyphs");
  }
  s.querySelector("#product-strength").textContent = d.strength;
  s.querySelector("#label-batch").textContent =
    t("pen.lot", { batch: d.batch || t("pen.unknown") });
  s.querySelector("#label-expiry").textContent =
    t("pen.exp", { expiry: d.expiry ? monthYear(d.expiry) : t("pen.unknown") });
  const f = d.totalClicks ? remainingClicks() / d.totalClicks : 1;
  s.querySelector("#piston-assembly").style.transform = `translateY(${(1 - f) * PISTON_TRAVEL}px)`;
  // progress-style windows show no readable number (docs/design-notes.md) —
  // drawing one on the graphic would imply the window shows the dose.
  s.querySelector("#dose-value").textContent =
    d.counterStyle === "progress" || activePen?.archivedAt ? "" : fmtU(unitsForClicks(doseClicks));
}
function showBack(back) {
  svg().classList.toggle("show-back", back);
  $("pen-caption").textContent = t(back ? "pen.back" : "pen.front");
}

/* ============ dose mode (ported) ============ */
function buildChips() {
  const box = $("chips");
  box.innerHTML = "";
  pen().common.forEach(u => {
    const b = document.createElement("button");
    b.textContent = fmtU(u) + " " + pen().unit;
    b.addEventListener("click", () => { doseClicks = clicksFor(u); renderDose(); });
    box.append(b);
  });
}

// The dial max is whatever the pen physically allows, further limited by what
// is actually left in it. `maxDialClicks` is null when unknown (custom pens).
// An empty pen clamps to 1 and blocks recording entirely (see renderDose) —
// the prototype fell back to the full dial max here, which let a user record a
// dose the pen could not have delivered.
function clampDose() {
  const dialMax = pen().maxDialClicks ?? Infinity;
  const max = Math.max(1, Math.min(dialMax, remainingClicks() || dialMax));
  doseClicks = Math.max(1, Math.min(doseClicks, max));
}

function renderDose() {
  clampDose();
  const d = pen();
  const u = unitsForClicks(doseClicks);
  $("seg-units").textContent = d.unit;
  $("seg-units").setAttribute("aria-pressed", entryUnit === "units");
  $("seg-clicks").setAttribute("aria-pressed", entryUnit === "clicks");
  const inp = $("f-dose");
  inp.value = entryUnit === "clicks" ? doseClicks : fmtU(u);
  inp.step = entryUnit === "clicks" ? 1 : "any";
  // Readout always leads with clicks — the action performed on the pen.
  // The sub-line depends on counter_style (docs/design-notes.md):
  //   numeric  → the window really shows the number
  //   progress → the window shows nothing readable; say so
  $("readout-big").textContent = clicks(doseClicks);
  $("readout-sub").textContent = d.counterStyle === "progress"
    ? t("dose.readout_progress", { units: fmtU(u), unit: d.unit })
    : t("dose.readout_numeric", { units: fmtU(u) });
  [ ...$("chips").children ].forEach((b, i) =>
    b.setAttribute("aria-pressed", clicksFor(d.common[i]) === doseClicks));
  // An empty pen can't deliver a dose, so don't offer to record one.
  const empty = remainingClicks() === 0;
  $("dose-now").disabled = empty;
  $("dose-now").textContent = t(empty ? "dose.empty_button" : "dose.now");
  // A finished or expired pen suggests archiving rather than trashing —
  // archiving keeps its history and batch number.
  $("archive-pen").hidden = !(empty || isExpired(d));
  // Derived once and passed down: this is the dial's hot path (every +/- tap
  // repaints), and activePlan/planStep each walk every pen's history.
  const plan = activePlan();
  const step = nextDoseStep(plan, pens);
  renderPlan(plan, step);
  renderForecast(plan, step);
  renderStatsWarnings(step);
  paintPen();
}

/* ============ dose plan: the dose screen (issue #21) ============ */
// Every line here is either a fact about this user's own data or a quotation
// from the cited document. counta states neither what the medicine requires
// nor what anyone should take: the AU and US product information give
// different missed-dose windows and different wording for several missed
// doses, so any paraphrase would be wrong in one of them. Facts, and a link.
function renderPlan(plan, step) {
  // `step` is null for a plan with no steps at all — not reachable from this
  // client's own setup form (planFormError refuses it), but reachable by
  // adopting another device's plan in a 409 merge, or from a malformed preset
  // row. Without this guard the dose screen throws and the pen won't open.
  $("plan-block").hidden = !plan || !step;
  if (!plan || !step) return;

  const d = pen();

  // Week wording comes from the source document when there is any; otherwise
  // the step's position in the ladder. Never a week computed from the
  // calendar, which would disagree with the dose position after a gap.
  const stepLabel = step.step.sourceLabel
    || t("plan.step_number", { number: step.index + 1, total: step.total });
  const remaining = step.complete
    ? t("plan.complete")
    : step.dosesLeftAtStep == null
      ? t("plan.ongoing")
      : t("plan.doses_left_at_step", { count: step.dosesLeftAtStep });
  let line = t("plan.step_line", {
    label: stepLabel, units: fmtU(step.step.units), unit: d.unit, remaining
  });
  if (step.stepsUpNext && step.dosesLeftAtStep === 1) {
    line += " " + t("plan.moves_next", { units: fmtU(step.nextStep.units), unit: d.unit });
  }
  $("plan-line").textContent = line;

  // The plan is the user's transcription of their prescription, so a pen that
  // can't dial it is reported, never quietly rewritten. (The dial itself is
  // still clamped by clampDose — a dose the pen cannot deliver must not be
  // recordable — but the user is told, rather than left with a silently
  // smaller number.)
  const undeliverable = stepUndeliverable(step.step, {
    clicksFor, maxDialClicks: d.maxDialClicks
  });
  $("plan-dial-warn").hidden = !undeliverable;
  if (undeliverable) {
    $("plan-dial-warn-text").textContent = t("plan.undeliverable", {
      units: fmtU(step.step.units), unit: d.unit,
      max: fmtU(unitsForClicks(d.maxDialClicks))
    });
  }

  renderPlanGap(plan, d);

  $("plan-source").hidden = !plan.source;
  if (plan.source) {
    $("plan-source").replaceChildren(
      ...tNodes("plan.source_line", { source: planSourceLink(plan.source) }));
  }
}

/* ============ next-dose forecast (issue #37) ============ */
// Two facts about the user's own schedule, in calendar language: when the next
// dose falls due, and what it will be. A display surface over derivations that
// already exist — the plan's next step (#21) and the pen's dose history — with
// no arithmetic of its own beyond one call to plan.js#addDays.
//
// DAY ONLY, no time of day, and that is a decision rather than an omission.
// Issue #37 asks to reuse #14's dosing-time proxy, but the proxy rounds a
// TIMESTAMP and nothing here has one: dose entries store a calendar date and
// no clock time, and the calendar fields in the blob hold a UID and a
// sequence number, not the rounded time an export used. Feeding the proxy the
// moment the page happened to load would put a confident "due at 2:15 pm" on
// screen built from when someone opened the app. #37's other requirement —
// that the calendar and this surface never disagree about dosing time — is
// then met by construction, because this surface makes no claim about it.
//
// `lastDose` is scoped to the PLAN when there is one, so it still reads right
// the day after a pen swap, when the last dose sits on the archived pen.
// The dose the forecast counts forward from. Plan-scoped when there is a plan,
// so it still reads right the day after a pen swap, when the last dose sits on
// the pen that was just archived.
function forecastAnchorDate(plan) {
  if (plan) return lastDoseDate(plan, pens);
  return byDate(pen().history ?? []).at(-1)?.date ?? null;
}

// The doses a dosing time may be read from. Plan-scoped when there is a plan,
// matching the date anchor above: a routine outlives the pen it was observed
// on, so the day after a pen swap the habit is still known.
function timeSourceEntries() {
  const plan = activePlan();
  return plan ? planDoses(plan, pens) : (pen().history ?? []);
}

function renderForecast(plan, step) {
  const d = pen();
  const anchor = forecastAnchorDate(plan);

  // Nothing to forecast from, and nothing to say about that: the history list
  // immediately below already reads "No doses yet", so a second empty state
  // here would be noise rather than help.
  $("forecast").hidden = !anchor;
  if (!anchor) return;

  // Two sources for the time, and the copy says which one it is. An observed
  // time is a fact about this person; the fall-back is a guess from the clock
  // right now, and reads as one.
  const entries = timeSourceEntries();
  const observed = lastDoseTime(entries);
  $("forecast-due").replaceChildren(...tNodes(
    observed ? "forecast.due_at" : "forecast.due_at_guess",
    { date: weekdayEl(addDays(anchor, d.freqDays)), time: timeEl24(dosingTime(entries, new Date())) }
  ));

  // The plan owns "how much" while it has something left to say. A finished
  // ladder doesn't, so it falls through to the same answer as an unplanned
  // pen — reusing the states #21 already built rather than inventing a third.
  if (step && !step.complete) {
    // Units derived from the CLICKS, not printed straight from the plan.
    // Clicks are canonical (docs/architecture.md decision 3), and 0.25 mg on
    // this pen is 8 clicks which is really 0.26 mg — printing the plan's
    // figure would contradict the readout the moment they dial it.
    const planClicks = clicksFor(step.step.units);
    $("forecast-amount").hidden = false;
    $("forecast-amount").textContent = t("forecast.amount_plan", {
      clicks: clicks(planClicks),
      units: fmtU(unitsForClicks(planClicks)), unit: d.unit
    });
    return;
  }
  // No plan: say plainly that this is a repeat of last time, rather than
  // wording it so it reads as a schedule the user never set up (#37). Taken
  // from THIS pen's history — a dose on a pen that has since been archived
  // says nothing about what this one is dialled to deliver.
  const previous = byDate(pen().history ?? []).at(-1);
  $("forecast-amount").hidden = !previous;
  if (!previous) return;
  $("forecast-amount").textContent = t("forecast.amount_last", {
    clicks: clicks(previous.clicks), units: fmtU(unitsForClicks(previous.clicks)), unit: d.unit
  });
}

// A wall-clock "HH:MM" rendered in the viewer's own clock convention, with the
// stored 24-hour value in datetime — so a spec asserts "18:00" whatever the
// locale renders (§9.9), and assistive tech gets the machine-readable form.
function timeEl24(hhmm) {
  const el = document.createElement("time");
  el.className = "forecast-time";
  el.dateTime = hhmm;
  const [ hour, minute ] = hhmm.split(":").map(Number);
  // Any date will do — only the clock fields are formatted.
  const shown = new Date(2000, 0, 1, hour, minute);
  // timeStyle, not hour/minute parts: on a 24-hour locale the parts form
  // renders 01:00 as a bare "1:00", which sits inconsistently next to "13:00"
  // and reads as ambiguous; timeStyle gives the locale's own short format,
  // zero-padded on 24-hour locales and carrying am/pm on 12-hour ones. A time
  // about medication should not need working out.
  el.textContent = shown.toLocaleTimeString(undefined, { timeStyle: "short" });
  return el;
}

// Like dateEl, but naming the weekday — "due Tuesday" is how people hold a
// weekly schedule. datetime still carries the plain calendar date, so specs
// assert something that doesn't move with the viewer's locale (§9.9).
function weekdayEl(isoDay) {
  const el = document.createElement("time");
  el.className = "forecast-date";
  el.dateTime = isoDay;
  el.textContent = localMidnight(isoDay)
    .toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "short" });
  return el;
}

// A dose date is a LOCAL calendar date string in the blob, not an instant:
// render it through localMidnight (new Date("2026-03-01") would parse as UTC),
// and put the stored string straight into datetime so specs assert something
// that doesn't move with the viewer's locale (AGENTS.md §9.6, §9.9).
function dateEl(isoDay) {
  const el = document.createElement("time");
  el.dateTime = isoDay;
  el.textContent = localDate(localMidnight(isoDay));
  return el;
}

function renderPlanGap(plan, d) {
  const missed = missedDoses(plan, pens, todayISO(), d.freqDays);
  // Two, not one, and not off by one: both labels reserve their re-initiation
  // wording for two or more consecutive missed doses, and the decision record
  // on issue #21 fixes the threshold there. A single late dose is ordinary and
  // counta says nothing about it. (Flagged in review once; leaving the reason
  // here so it isn't re-flagged.)
  $("plan-gap").hidden = missed < 2;
  if (missed < 2) return;

  const last = lastDoseDate(plan, pens);
  $("plan-gap-text").replaceChildren(...tNodes(
    "plan.gap",
    { date: dateEl(last) },
    {
      ago: t("plan.days_ago", { count: daysBetween(last, todayISO()) }),
      frequency: t("frequency.days", { count: d.freqDays })
    }
  ));

  const href = safeHref(plan.source?.url);
  $("plan-gap-source").hidden = !href;
  if (href) {
    $("plan-gap-source").href = href;
    $("plan-gap-source").textContent = t("plan.gap_read_source", { source: plan.source.label });
  }
}

function renderStatsWarnings(step) {
  const d = pen();
  const rc = remainingClicks(), ru = unitsForClicks(rc);
  // `dp` is pen capacity at the size actually dialled, and drives everything
  // below — the expiry projection and the running-low warnings, whose wording
  // has always been about the pen. Deriving it from the PLAN's step size
  // instead was wrong twice over: an undeliverable step (more clicks than the
  // dial or the pen has left) made a brand-new pen report "this is the last
  // full dose", and a step rounding to zero clicks made it report "not enough
  // left for a full dose". doseClicks is clamped to something this pen can
  // deliver, so it never lies that way.
  const dp = remainingDoses();
  // `rd` is the plan's own number and reaches exactly one place: the tile.
  const rd = step ? planDosesLeft() : dp;
  const ml = d.capMl ? ` · ${(d.capMl * rc / d.totalClicks).toFixed(2)} mL` : "";
  $("stats").innerHTML =
    `<div class="stat"><div class="v">${esc(fmtU(ru))}</div><div class="k">${esc(unitsLeftLabel(d, rc))}</div></div>` +
    `<div class="stat"><div class="v">${rd}</div><div class="k">${esc(step
      ? t("stats.doses_left_at_step", { units: fmtU(step.step.units), unit: d.unit })
      : t("stats.doses_left"))}</div></div>` +
    `<div class="stat"><div class="v">${rc}</div><div class="k">${esc(t("stats.clicks_left"))}</div></div>`;
  const w = [];
  const today = startOfToday();
  if (d.expiry) {
    const expEnd = expiryEnd(d);
    if (expEnd < today) {
      w.push([ "red", t("warnings.expired", { expiry: monthYear(d.expiry) }) ]);
    } else if (dp > 0) {
      const runout = new Date(today);
      runout.setDate(runout.getDate() + Math.ceil(dp * d.freqDays));
      if (runout > expEnd) {
        const dosesByExp = Math.floor((expEnd - today) / (864e5 * d.freqDays));
        w.push([ "amber", t("warnings.expiring_soon", {
          count: dosesByExp,
          frequency: t("frequency.days", { count: d.freqDays }),
          expiry: monthYear(d.expiry),
          remaining: t("warnings_doses", { count: dp })
        }) ]);
      }
    }
  }
  if (rc === 0) w.push([ "red", t("warnings.empty") ]);
  else if (dp <= 1) w.push([ "amber", t(dp === 1 ? "warnings.last_dose" : "warnings.part_dose") ]);
  $("warnings").innerHTML = w.map(([ c, t ]) =>
    `<div class="warn ${c}"><span aria-hidden="true">${c === "red" ? "⛔" : "⚠️"}</span><span>${esc(t)}</span></div>`).join("");
}

function renderHistory() {
  const ul = $("history");
  const h = pen().history;
  if (!h.length) {
    ul.innerHTML = `<li class="empty">${esc(t("history.empty"))}</li>`;
    return;
  }
  const short = iso => localMidnight(iso).toLocaleDateString(undefined, { day: "numeric", month: "short" });
  // Doses can be backdated, so history is in entry order, not date order —
  // sort before taking the most recent five.
  ul.innerHTML = byDate(h).slice(-5).reverse().map(e =>
    // Units are derived from clicks at render time: clicks are canonical, and
    // a stored figure would go stale if the pen's capacity is ever corrected.
    `<li><span>${esc(short(e.date))}</span><span><strong>${esc(clicks(e.clicks))}</strong> ` +
    `<span class="mgv">${esc(t("history.entry_units", { units: fmtU(unitsForClicks(e.clicks)), unit: pen().unit }))}</span></span></li>`).join("");
}

/* ============ first-run / auth flows ============ */
async function startSignup() {
  clearError("landing-error");
  $("disclaimer-dlg").showModal();
}

// Fresh user-activation for a follow-up WebAuthn call (see passkeys.js).
function requestGesture() {
  return new Promise(resolve => {
    $("gesture-dlg").showModal();
    $("gesture-continue").addEventListener("click", () => {
      $("gesture-dlg").close();
      resolve();
    }, { once: true });
  });
}

async function completeSignup() {
  try {
    const res = await signup({ requestGesture });
    dek = res.dek;
    accountId = res.accountId;
    await showKitCeremony(res.kitWords);
    await loadApp();
  } catch (e) {
    if (e instanceof PrfUnsupportedError) {
      $("prf-dlg").showModal();
    } else {
      console.error(e);
      showError("landing-error", new Error(t("errors.generic")));
    }
  }
}

function showKitCeremony(words) {
  return new Promise(resolve => {
    $("kit-account").textContent = accountId;
    const ol = $("kit-words");
    ol.innerHTML = "";
    words.forEach(w => {
      const li = document.createElement("li");
      li.textContent = w;
      ol.append(li);
    });
    const kitJson = JSON.stringify({
      app: "counta.click", version: 1, account_id: accountId, words
    }, null, 2);
    $("kit-download").href = URL.createObjectURL(new Blob([ kitJson ], { type: "application/json" }));
    $("kit-saved-check").checked = false;
    $("kit-done").disabled = true;
    $("kit-dlg").showModal();
    $("kit-done").addEventListener("click", () => {
      $("kit-dlg").close();
      resolve();
    }, { once: true });
  });
}

async function doSignIn(errEl) {
  clearError(errEl);
  try {
    const res = await signIn();
    dek = res.dek;
    accountId = res.accountId;
    await loadApp();
  } catch (e) {
    console.error(e);
    showError(errEl, new Error(t(e instanceof PrfUnsupportedError
      ? "errors.prf_unsupported" : "errors.sign_in_failed")));
  }
}

async function doRecover() {
  clearError("rec-error");
  try {
    const words = $("rec-words").value.split(/[\s,]+/).filter(Boolean);
    const res = await recoverWithKit($("rec-account").value.trim(), words);
    dek = res.dek;
    accountId = res.accountId;
    await loadApp();
    announce(t("status.recovered"));
  } catch (e) {
    console.error(e);
    // Kit-entry mistakes (wrong word count, unknown word, bad checksum) are
    // raised locally before any request, so they carry no status — and their
    // messages are the only actionable feedback available. Keep them.
    showError("rec-error", e.status === undefined ? e
      : new Error(t(e.status === 401 ? "errors.recovery_mismatch" : "errors.generic")));
  }
}

/* ============ account panel ============ */
function renderArchivedList() {
  const ul = $("archived-list");
  const archived = pens.filter(p => p.archivedAt);
  if (!archived.length) {
    ul.innerHTML = `<li class="empty">${esc(t("archived.list_empty"))}</li>`;
    return;
  }
  ul.innerHTML = "";
  archived.forEach(p => {
    const li = document.createElement("li");
    const label = document.createElement("span");
    label.textContent = t("archived.list_label", { name: p.data.name, date: localDate(p.archivedAt) });
    const open = document.createElement("button");
    open.className = "linklike";
    open.textContent = t("archived.list_open");
    // Several rows means several "Open" buttons — name each one so screen
    // reader users (and click_button) can tell them apart.
    open.setAttribute("aria-label",
      t("archived.list_open_label", { name: p.data.name, date: localDate(p.archivedAt) }));
    open.addEventListener("click", () => {
      activePen = p;
      editingPen = null;
      show("app-screen");
      enterDoseMode();
    });
    li.append(label, open);
    ul.append(li);
  });
}

async function openAccountPanel() {
  clearError("account-error");
  $("acct-id").textContent = accountId;
  renderArchivedList();
  const creds = await api("/api/credentials");
  $("passkey-list").innerHTML = creds.map((c, i) =>
    `<li><span>${esc(t("account.passkey_row", { number: i + 1 }))}</span>` +
    `<span class="mgv">${esc(t("account.passkey_added", { date: localDate(c.created_at) }))}</span></li>`).join("");
  show("account-screen");
}

/* ============ ICS export ============ */
// calendarUid/calendarSequence live in the pen's own encrypted blob, not on
// the server row: a stable UID that survives the pen row being recreated
// from a preserved blob, and a counter a client can use to know an export
// supersedes the last one (RFC 5545 SEQUENCE) — see #14 "Re-export shouldn't
// duplicate". Minted/bumped here, persisted, THEN handed to buildIcs, so
// icsPreview (test_hooks.js) sees exactly what a real export would.
async function buildIcsForExport(now = new Date()) {
  if (remainingDoses() < 1) return null;
  const d = pen();
  const snapshotUid = d.calendarUid, snapshotSequence = d.calendarSequence;
  if (!d.calendarUid) d.calendarUid = crypto.randomUUID();
  d.calendarSequence = (d.calendarSequence || 0) + 1;
  try {
    // bumpCalendarSequence: this write's INTENT is to advance the counter,
    // so on a 409 the conflict handler must rebase the bump onto whatever
    // the winning device already stored, not silently keep this device's
    // now-stale guess (see the merge-policy comment in persistPen).
    await persistPen(activePen, { bumpCalendarSequence: true });
  } catch (e) {
    d.calendarUid = snapshotUid;
    d.calendarSequence = snapshotSequence;
    throw e;
  }
  // The same entries the on-screen forecast reads its time from, so the two
  // surfaces cannot name different times (#37's one-proxy rule). Plan-scoped
  // when there is a plan, because a habit outlives the pen it was observed on.
  return buildIcs(d, activePen.id, remainingDoses(), doseClicks,
    `${fmtU(unitsForClicks(doseClicks))} ${d.unit}`, now, timeSourceEntries());
}

async function downloadIcs() {
  const ics = await buildIcsForExport();
  if (!ics) {
    alert(t("errors.nothing_to_schedule"));
    return;
  }
  const d = pen();
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([ ics ], { type: "text/calendar" }));
  a.download = `counta-${d.name.toLowerCase().replace(/[^a-z0-9]+/g, "-")}.ics`;
  a.click();
  URL.revokeObjectURL(a.href);
}

/* ============ events ============ */
function wire() {
  // landing
  $("landing-create").addEventListener("click", startSignup);
  $("landing-signin").addEventListener("click", () => doSignIn("landing-error"));
  $("landing-recover").addEventListener("click", () => { clearError("rec-error"); show("recovery-screen"); });
  $("landing-flush").addEventListener("click", async () => {
    try {
      await api("/device/flush", { method: "POST" });
    } catch (e) {
      console.error(e);
      showError("landing-error", new Error(t("errors.generic")));
      return;
    }
    // Deliberately does not claim a deletion: the endpoint is a stub until
    // push notifications exist, and there is nothing to delete yet.
    announce(t("status.push_none"));
    alert(t("errors.push_none"));
  });

  // disclaimer / prf dialogs
  $("disclaimer-accept").addEventListener("click", () => { $("disclaimer-dlg").close(); completeSignup(); });
  $("disclaimer-cancel").addEventListener("click", () => $("disclaimer-dlg").close());
  $("prf-retry").addEventListener("click", () => { $("prf-dlg").close(); completeSignup(); });
  $("prf-cancel").addEventListener("click", () => $("prf-dlg").close());

  // kit ceremony
  $("kit-saved-check").addEventListener("change", e => { $("kit-done").disabled = !e.target.checked; });

  // unlock
  $("unlock-btn").addEventListener("click", () => doSignIn("unlock-error"));
  $("unlock-signout").addEventListener("click", async () => { await signOut(); dek = null; show("landing-screen"); });

  // recovery
  $("rec-submit").addEventListener("click", doRecover);
  $("rec-cancel").addEventListener("click", () => show("landing-screen"));
  $("rec-file").addEventListener("change", async e => {
    const file = e.target.files[0];
    if (!file) return;
    try {
      const kit = JSON.parse(await file.text());
      $("rec-account").value = kit.account_id || "";
      $("rec-words").value = (kit.words || []).join(" ");
    } catch {
      showError("rec-error", new Error(t("errors.kit_file_invalid")));
    }
  });

  // pen switcher
  $("chip").addEventListener("change", e => {
    if (e.target.value === "__add__") {
      editingPen = null;
      buildProductSelect();
      fillSetupForm(products[0].id);
      enterSetup(pens.length > 0);
      return;
    }
    const p = pens.find(x => x.id === e.target.value);
    if (p) {
      activePen = p;
      editingPen = null;
      enterDoseMode();
    }
  });

  // archive / unarchive
  $("archive-pen").addEventListener("click", () => setArchived(true));
  $("archive-pen-edit").addEventListener("click", () => { activePen = editingPen; setArchived(true); });
  $("unarchive-pen").addEventListener("click", () => setArchived(false));

  // setup
  $("f-product").addEventListener("change", e => { fillSetupForm(e.target.value); previewSetupPen(); });
  // Typing a custom pen's name should show up on the label as you go.
  $("f-name").addEventListener("input", previewSetupPen);
  $("f-capacity").addEventListener("change", e => {
    const p = productByKey($("f-product").value);
    $("custom-cap-wrap").hidden = e.target.value !== "custom";
    if (e.target.value !== "custom") $("f-clicks").value = p.total_clicks;
  });
  // dose plan
  $("f-plan").addEventListener("change", syncPlanUi);
  $("f-plan-progress").addEventListener("change", syncPlanUi);
  $("f-plan-prior").addEventListener("input", syncPlanUi);
  $("f-plan-start").addEventListener("change", e => {
    // Marked as the user's own once they touch it, so the start date stops
    // being recomputed underneath them when they revise their position.
    e.target.dataset.touched = "true";
    syncPlanUi();
  });
  // The gap notice's only action: open this pen's settings, where the plan is.
  // counta doesn't change the plan itself — that's between the user and their
  // prescriber.
  $("plan-gap-edit").addEventListener("click", () => $("edit-pen").click());

  $("save-pen").addEventListener("click", () => savePenForm().catch(e => alert(e.message)));
  $("cancel-setup").addEventListener("click", () => { editingPen = null; enterDoseMode(); });
  $("edit-pen").addEventListener("click", () => {
    editingPen = activePen;
    const d = pen();
    buildProductSelect();
    fillSetupForm(d.productKey);
    if (d.productKey === "custom") {
      $("f-name").value = d.name;
      $("f-counter-style").value = d.counterStyle || "progress";
    }
    // fillSetupForm resets capacity to the product preset, so a pen set up
    // with a custom capacity must have it restored — otherwise editing (say)
    // the expiry silently rewrites capacity back to the preset and every
    // future clicks-to-mg conversion is wrong on a pen that holds something
    // else entirely.
    const preset = productByKey(d.productKey);
    const usesPreset = preset.capacity_units != null &&
      Number(preset.capacity_units) === Number(d.capUnits);
    $("f-capacity").value = usesPreset ? "0" : "custom";
    $("custom-cap-wrap").hidden = usesPreset;
    if (!usesPreset) {
      $("f-cap-units").value = d.capUnits;
      $("f-cap-unitname").value = d.unit;
    }
    $("f-batch").value = d.batch;
    $("f-expiry").value = d.expiry;
    $("f-clicks").value = d.totalClicks;
    $("f-freq").value = String(d.freqDays);
    enterSetup(true);
  });

  // dose entry
  $("seg-units").addEventListener("click", () => { entryUnit = "units"; renderDose(); $("f-dose").focus(); });
  $("seg-clicks").addEventListener("click", () => { entryUnit = "clicks"; renderDose(); $("f-dose").focus(); });
  $("minus").addEventListener("click", () => { doseClicks--; renderDose(); });
  $("plus").addEventListener("click", () => { doseClicks++; renderDose(); });
  $("f-dose").addEventListener("change", e => {
    const v = parseFloat(e.target.value) || 0;
    doseClicks = entryUnit === "clicks" ? Math.round(v) : clicksFor(v);
    renderDose();
  });
  $("dose-now").addEventListener("click", () => {
    $("confirm-clicks").textContent = clicks(doseClicks);
    const dte = $("f-date").value || todayISO();
    $("confirm-mg").textContent = t("dose.confirm_sub", {
      units: fmtU(unitsForClicks(doseClicks)), unit: pen().unit,
      date: dte === todayISO() ? t("dose.today") : localDate(localMidnight(dte))
    });
    $("confirm-dlg").showModal();
  });
  $("confirm-yes").addEventListener("click", async () => {
    $("confirm-dlg").close();
    // Stable id per dose so a merge can tell "the same dose, seen twice"
    // from "two identical doses on the same day", which are indistinguishable
    // by their contents alone.
    // Pressing "Dose now" is a better observation of when someone doses than
    // anything counta could ask for — they are doing it as they press it — so
    // the moment is captured, rounded to the half hour, and kept with the
    // dose. Stored as a wall-clock "HH:MM", not an instant, so 18:00 stays
    // 18:00 across a daylight-saving change (AGENTS.md §9.6).
    //
    // Only for a dose entered as TODAY. A backdated dose happened at some
    // other time entirely, and stamping the present moment on it would invent
    // an observation — the one thing this field must not do, since the
    // calendar export sets real reminders from it.
    const enteredDate = $("f-date").value || todayISO();
    const entry = { id: crypto.randomUUID(), date: enteredDate,
                    clicks: doseClicks, units: unitsForClicks(doseClicks),
                    ...(enteredDate === todayISO() ? { time: captureDosingTime(new Date()) } : {}) };
    pen().history.push(entry);
    try {
      await persistPen(activePen);
    } catch (e) {
      // Remove THIS dose, not "the last one": a merge sorts by date, so the
      // entry at the end may be someone else's.
      pen().history = pen().history.filter(h => h.id !== entry.id);
      console.error(e);
      alert(t("errors.save_dose"));
      return;
    }
    renderHistory();
    // Captured BEFORE the re-dial below, which moves doseClicks on to the next
    // step's amount: reading the global afterwards announced the dose you are
    // about to take, not the one just recorded — "Dose recorded: 15 clicks"
    // for an 8-click dose. Screen-reader users get no visual to correct it.
    const recordedClicks = entry.clicks;
    // The dose just recorded may have completed a step, so re-dial before
    // rendering — see syncDialToPlan.
    syncDialToPlan();
    renderDose();
    buildSwitcher(); // % remaining in the switcher label stays live
    // The forecast changes at exactly this moment, and it is deliberately not
    // its own live region — two regions speaking at once is how one of them
    // gets dropped. Folded into the one announcement instead, so a screen
    // reader user hears the new due day without having to go looking for it.
    // querySelector, not $: $ is getElementById and cannot take a descendant.
    const due = $("forecast").hidden
      ? null
      : document.querySelector("#forecast-due .forecast-date")?.textContent;
    announce(due
      ? t("status.dose_recorded_next", {
          count: recordedClicks, remaining: remainingClicks(), date: due })
      : t("status.dose_recorded", { count: recordedClicks, remaining: remainingClicks() }));
  });
  $("confirm-no").addEventListener("click", () => $("confirm-dlg").close());
  $("info-btn").addEventListener("click", () => $("info-dlg").showModal());
  $("info-close").addEventListener("click", () => $("info-dlg").close());

  // trash pen (from the archived view or the edit screen)
  $("trash-pen").addEventListener("click", () => $("trash-dlg").showModal());
  $("trash-pen-edit").addEventListener("click", () => { activePen = editingPen; $("trash-dlg").showModal(); });
  $("trash-no").addEventListener("click", () => $("trash-dlg").close());
  $("trash-yes").addEventListener("click", async () => {
    $("trash-dlg").close();
    try {
      if (activePen.id) await api(`/api/pens/${activePen.id}`, { method: "DELETE" });
    } catch (e) {
      console.error(e);
      alert(t("errors.trash_pen"));
      return;
    }
    pens = pens.filter(p => p !== activePen);
    editingPen = null;
    activePen = activePens()[0] || pens[0] || null;
    if (activePen) {
      enterDoseMode();
    } else {
      buildProductSelect();
      fillSetupForm(products[0].id);
      enterSetup(false);
    }
  });

  // ICS
  $("export-ics").addEventListener("click", () => $("ics-dlg").showModal());
  $("ics-no").addEventListener("click", () => $("ics-dlg").close());
  $("ics-yes").addEventListener("click", () => {
    $("ics-dlg").close();
    downloadIcs().catch(e => { console.error(e); alert(t("errors.save_ics")); });
  });

  // account panel
  $("account-btn").addEventListener("click", () => openAccountPanel().catch(e => showError("account-error", e)));
  $("account-back").addEventListener("click", () => show("app-screen"));
  $("sign-out").addEventListener("click", async () => { await signOut(); dek = null; accountId = null; show("landing-screen"); });
  $("add-passkey").addEventListener("click", async () => {
    clearError("account-error");
    try {
      await addPasskey(dek, { requestGesture });
      await openAccountPanel();
      announce(t("status.passkey_added"));
    } catch (e) {
      console.error(e);
      showError("account-error", new Error(t(e instanceof PrfUnsupportedError
        ? "errors.prf_unsupported" : "errors.generic")));
    }
  });
  $("delete-account").addEventListener("click", () => $("delete-dlg").showModal());
  $("delete-no").addEventListener("click", () => $("delete-dlg").close());
  $("delete-yes").addEventListener("click", async () => {
    $("delete-dlg").close();
    try {
      await deleteAccount();
    } catch (e) {
      console.error(e);
      showError("account-error", new Error(t("errors.delete_account")));
      return;
    }
    dek = null;
    accountId = null;
    pens = [];
    activePen = null;
    show("landing-screen");
    announce(t("status.account_deleted"));
  });
}

/* ============ test hooks ============ */
// The specs need to drive the envelope directly — encrypt a probe, act as a
// second device — which means reaching this module's private state, the DEK
// most of all. That lives in its own module, dynamically imported and only in
// the test environment: it isn't pinned elsewhere, so a real browser never
// fetches or parses it. Getters, not values, because `dek` is null until
// unlock and a snapshot would be null forever.
if (document.querySelector('meta[name="test-hooks"]')?.content === "true") {
  import("test_hooks").then(({ install }) => install({
    api, encryptPayload, decryptPayload, buildIcsForExport,
    dek: () => dek,
    accountId: () => accountId,
    pen: () => pen(),
    activePen: () => activePen,
    doseClicks: () => doseClicks,
    remainingDoses: () => remainingDoses(),
    fmtU, unitsForClicks
  }));
}

/* ============ boot ============ */
wire();
if (document.querySelector('meta[name="signed-in"]').content === "true") {
  show("unlock-screen");
} else {
  show("landing-screen");
}
