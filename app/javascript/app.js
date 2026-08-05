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
const remainingDoses = () => doseClicks > 0 ? Math.floor(remainingClicks() / doseClicks) : 0;
const unitsPerClick = () => pen().capUnits / pen().totalClicks;
// Trim trailing zeros, but only after the decimal point: "10.00" -> "10",
// "1.70" -> "1.7", "0.26" -> "0.26". The original single-zero strip left
// whole numbers reading "10.0".
const fmtU = v => pen().decimals
  ? (Math.round(v * 100) / 100).toFixed(2).replace(/\.?0+$/, "")
  : Math.round(v).toString();
const clicksFor = u => Math.round(u / unitsPerClick());
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
    const snapshot = { history: p.data.history, updatedAt: p.updatedAt, archived };
    try {
      const theirs = await decryptPayload(dek, e.body.blob);
      p.data.history = mergeHistory(p.data.history || [], theirs.history || []);
      p.updatedAt = e.body.updated_at;
      // If the other device archived the pen, a dose save must not undo that:
      // this write never intended to change archive state, so adopt theirs.
      if (!archiveIsIntentional) archived = e.body.archived_at != null;
      adoptRow(p, await write());
    } catch (retryError) {
      p.data.history = snapshot.history;
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
}

function enterSetup(fromDose) {
  $("setup-card").hidden = false;
  $("dose-card").hidden = true;
  $("cancel-setup").hidden = !fromDose;
  // Archive/trash live on the edit screen ("settings"), never on new-pen setup.
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
  const data = {
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
    history: editingPen ? editingPen.data.history : [],
    registrationIds: editingPen ? editingPen.data.registrationIds : []
  };

  // Don't mutate local state until the server has it: a failed save used to
  // leave the UI (and the switcher) showing a pen the server never received.
  const target = editingPen ?? { id: null, data: null };
  const previousData = target.data;
  target.data = data;
  const isNew = !editingPen;
  if (isNew) pens.push(target);
  try {
    await persistPen(target);
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
    $("f-date").value = todayISO();
    buildChips();
    renderDose();
  }
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
function paintPen() {
  const d = pen();
  if (!d) return;
  const s = svg();
  for (const [ k, v ] of Object.entries(d.theme)) s.style.setProperty(k, v);
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
  renderStatsWarnings();
  paintPen();
}

function renderStatsWarnings() {
  const d = pen();
  const rc = remainingClicks(), ru = unitsForClicks(rc);
  const rd = remainingDoses();
  const ml = d.capMl ? ` · ${(d.capMl * rc / d.totalClicks).toFixed(2)} mL` : "";
  $("stats").innerHTML =
    `<div class="stat"><div class="v">${esc(fmtU(ru))}</div><div class="k">${esc(unitsLeftLabel(d, rc))}</div></div>` +
    `<div class="stat"><div class="v">${rd}</div><div class="k">${esc(t("stats.doses_left"))}</div></div>` +
    `<div class="stat"><div class="v">${rc}</div><div class="k">${esc(t("stats.clicks_left"))}</div></div>`;
  const w = [];
  const today = startOfToday();
  if (d.expiry) {
    const expEnd = expiryEnd(d);
    if (expEnd < today) {
      w.push([ "red", t("warnings.expired", { expiry: monthYear(d.expiry) }) ]);
    } else if (rd > 0) {
      const runout = new Date(today);
      runout.setDate(runout.getDate() + Math.ceil(rd * d.freqDays));
      if (runout > expEnd) {
        const dosesByExp = Math.floor((expEnd - today) / (864e5 * d.freqDays));
        w.push([ "amber", t("warnings.expiring_soon", {
          count: dosesByExp,
          frequency: t("frequency.days", { count: d.freqDays }),
          expiry: monthYear(d.expiry),
          remaining: t("warnings_doses", { count: rd })
        }) ]);
      }
    }
  }
  if (rc === 0) w.push([ "red", t("warnings.empty") ]);
  else if (rd <= 1) w.push([ "amber", t(rd === 1 ? "warnings.last_dose" : "warnings.part_dose") ]);
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
function downloadIcs() {
  const d = pen();
  const ics = buildIcs(d, activePen.id, remainingDoses(), doseClicks,
    `${fmtU(unitsForClicks(doseClicks))} ${d.unit}`);
  if (!ics) {
    alert(t("errors.nothing_to_schedule"));
    return;
  }
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
  $("f-product").addEventListener("change", e => fillSetupForm(e.target.value));
  $("f-capacity").addEventListener("change", e => {
    const p = productByKey($("f-product").value);
    $("custom-cap-wrap").hidden = e.target.value !== "custom";
    if (e.target.value !== "custom") $("f-clicks").value = p.total_clicks;
  });
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
    const entry = { id: crypto.randomUUID(), date: $("f-date").value || todayISO(),
                    clicks: doseClicks, units: unitsForClicks(doseClicks) };
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
    renderDose();
    buildSwitcher(); // % remaining in the switcher label stays live
    announce(t("status.dose_recorded", { count: doseClicks, remaining: remainingClicks() }));
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
  $("ics-yes").addEventListener("click", () => { $("ics-dlg").close(); downloadIcs(); });

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
// Used by the system specs to prove the envelope end-to-end without going
// through the pen UI. Deliberately NOT shipped in production: it grants no
// capability injected script couldn't reach through module scope anyway, but
// it's a ready-made one-call plaintext oracle, and there's no reason to hand
// that to an attacker to save them the trouble.
if (document.querySelector('meta[name="test-hooks"]')?.content === "true") {
window.countaTest = {
  unlocked: () => dek !== null,
  accountId: () => accountId,
  async encryptProbe(text) {
    const blob = await encryptPayload(dek, { v: 1, probe: text });
    const res = await api("/api/pens", { method: "POST", body: { blob } });
    return res.id;
  },
  async decryptProbe() {
    const rows = await api("/api/pens");
    if (!rows.length) throw new Error("no pens");
    const data = await decryptPayload(dek, rows[0].blob);
    return data.probe;
  },
  // Simulates a second device writing to the same pen: reads the current
  // row, appends a dose, and writes it back correctly. The open UI's cached
  // updatedAt then points at a superseded version — exactly the stale-tab
  // situation, produced through the real API rather than by faking a 409.
  async simulateOtherDevice(dateISO) {
    const [ row ] = await api("/api/pens");
    const data = await decryptPayload(dek, row.blob);
    data.history.push({ id: crypto.randomUUID(), date: dateISO, clicks: 8,
                        units: 8 * (data.capUnits / data.totalClicks) });
    await api(`/api/pens/${row.id}`, { method: "PUT", body: {
      blob: await encryptPayload(dek, data), archived: row.archived_at != null,
      expected_updated_at: row.updated_at
    } });
    return data.history.length;
  },
  rows: () => api("/api/pens"),
  decryptRow: row => decryptPayload(dek, row.blob),
  // Writes a payload as if from another device, at the row's current version.
  async writeRow(row, data) {
    const [ current ] = await api("/api/pens");
    return api(`/api/pens/${current.id}`, { method: "PUT", body: {
      blob: await encryptPayload(dek, data), archived: current.archived_at != null,
      expected_updated_at: current.updated_at
    } });
  },
  // Another device archives the pen; this tab's cached state stays stale.
  async archiveElsewhere() {
    const [ row ] = await api("/api/pens");
    return api(`/api/pens/${row.id}`, { method: "PUT", body: {
      blob: row.blob, archived: true, expected_updated_at: row.updated_at
    } });
  },
  async historyFromServer() {
    const [ row ] = await api("/api/pens");
    return (await decryptPayload(dek, row.blob)).history;
  },
  // Exact string the ICS download would contain (same code path).
  icsPreview() {
    const d = pen();
    return buildIcs(d, activePen.id, remainingDoses(), doseClicks,
      `${fmtU(unitsForClicks(doseClicks))} ${d.unit}`);
  }
};
}

/* ============ boot ============ */
wire();
if (document.querySelector('meta[name="signed-in"]').content === "true") {
  show("unlock-screen");
} else {
  show("landing-screen");
}
