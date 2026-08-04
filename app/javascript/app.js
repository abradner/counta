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

const $ = id => document.getElementById(id);
const PISTON_TRAVEL = 160;

// Fallback preset for "Something else…" pens (no product row).
const CUSTOM_PRESET = {
  id: "custom", name: "", strength: "", unit: "mg", decimals: 2,
  counter_style: "numeric", capacity_units: null, capacity_ml: null,
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
const fmtU = v => pen().decimals ? (Math.round(v * 100) / 100).toFixed(2).replace(/0$/, "").replace(/\.$/, "") : Math.round(v).toString();
const clicksFor = u => Math.round(u / unitsPerClick());
const unitsForClicks = c => c * unitsPerClick();
// Local-calendar date. Never toISOString() — that converts to UTC and lands a
// day early/late for anyone not on UTC (AGENTS.md §9.6).
const isoDate = d =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const todayISO = () => isoDate(new Date());
const announce = msg => { $("sr-live").textContent = msg; };

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
// Retention TTL for archived pens: 2 years from the archive date. Sent as a
// plaintext date so the server-side purge job can honour it without reading
// the blob; the archive state itself stays encrypted.
function purgeAfterFor(data) {
  if (!data.archivedOn) return null;
  const d = new Date(data.archivedOn + "T00:00");
  d.setFullYear(d.getFullYear() + 2);
  return isoDate(d);
}

async function persistPen(p) {
  const body = { blob: await encryptPayload(dek, p.data), purge_after: purgeAfterFor(p.data) };
  if (p.id) {
    const res = await api(`/api/pens/${p.id}`, { method: "PUT", body });
    p.updatedAt = res.updated_at;
  } else {
    const res = await api("/api/pens", { method: "POST", body });
    p.id = res.id;
    p.updatedAt = res.updated_at;
  }
}

async function loadPens() {
  const rows = await api("/api/pens");
  pens = [];
  // Expiry of archived pens is enforced server-side by PenPurgeJob against
  // the plaintext purge_after TTL — nothing to prune here.
  for (const row of rows) {
    pens.push({ id: row.id, updatedAt: row.updated_at, data: await decryptPayload(dek, row.blob) });
  }
  activePen = pens.find(p => !p.data.archivedOn) || pens[0] || null;
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
  sel.append(new Option("Something else…", "custom"));
}

function fillSetupForm(key) {
  const p = productByKey(key);
  $("f-product").value = key;
  $("custom-name-wrap").hidden = key !== "custom";
  const cap = $("f-capacity");
  cap.innerHTML = "";
  if (p.capacity_label) cap.append(new Option(p.capacity_label, "0"));
  cap.append(new Option("Custom…", "custom"));
  cap.value = p.capacity_label ? "0" : "custom";
  $("custom-cap-wrap").hidden = cap.value !== "custom";
  $("f-clicks").value = p.total_clicks ?? "";
  $("clicks-hint").textContent = p.capacity_label
    ? `Pre-filled: ${p.total_clicks} clicks (${p.name} ${p.capacity_label}). Override for a custom pen.`
    : "Count from your pen’s dose table, or dial a full pen to check.";
  $("f-freq").value = String(p.default_freq_days);
}

function enterSetup(fromDose) {
  $("setup-card").hidden = false;
  $("dose-card").hidden = true;
  $("cancel-setup").hidden = !fromDose;
  // Archive/trash live on the edit screen ("settings"), never on new-pen setup.
  $("archive-pen-edit").hidden = !editingPen || !!editingPen.data.archivedOn;
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
    alert("Need pen capacity and total clicks to do click math.");
    return;
  }
  const data = {
    v: 1,
    productKey: key,
    name: key === "custom" ? ($("f-name").value || "My pen") : p.name,
    strength: key === "custom" ? "" : p.strength,
    unit: unitName, decimals: p.decimals,
    counterStyle: p.counter_style,
    capUnits, capMl, totalClicks,
    batch: $("f-batch").value.trim(), expiry: $("f-expiry").value,
    freqDays: parseFloat($("f-freq").value),
    maxDialClicks: p.max_dial_clicks === null ? Infinity : p.max_dial_clicks,
    common: p.common_doses, theme: p.theme,
    history: editingPen ? editingPen.data.history : [],
    registrationIds: editingPen ? editingPen.data.registrationIds : [],
    archivedOn: editingPen ? editingPen.data.archivedOn ?? null : null
  };

  if (editingPen) {
    editingPen.data = data;
    activePen = editingPen;
  } else {
    activePen = { id: null, data };
    pens.push(activePen);
  }
  await persistPen(activePen);
  editingPen = null;
  enterDoseMode();
  announce("Pen saved. Dose screen ready.");
}

// The header chip is the pen switcher: active pens (with % remaining), an
// Archived group, and the add-a-pen entry (docs/design-notes.md "Multi-pen").
function penLabel(p) {
  const d = p.data;
  if (d.archivedOn) return [ d.name, "archived" ].filter(Boolean).join(" · ");
  const pct = d.totalClicks ? Math.round(remainingClicksOf(d) / d.totalClicks * 100) : 100;
  return [ d.name, d.strength, `${pct}%` ].filter(Boolean).join(" · ");
}

function buildSwitcher() {
  const sel = $("chip");
  sel.innerHTML = "";
  pens.filter(p => !p.data.archivedOn).forEach(p => sel.append(new Option(penLabel(p), p.id)));
  const archived = pens.filter(p => p.data.archivedOn);
  if (archived.length) {
    const group = document.createElement("optgroup");
    group.label = "Archived";
    archived.forEach(p => group.append(new Option(penLabel(p), p.id)));
    sel.append(group);
  }
  sel.append(new Option("＋ Add a pen", "__add__"));
  if (activePen?.id) sel.value = activePen.id;
  sel.hidden = pens.length === 0;
}

function isExpired(d) {
  if (!d.expiry) return false;
  return new Date(+d.expiry.slice(0, 4), +d.expiry.slice(5, 7), 0) < new Date(todayISO());
}

function archivedCopy(d) {
  const fmt = dt => dt.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
  const from = new Date(d.archivedOn + "T00:00");
  const until = new Date(from);
  until.setFullYear(until.getFullYear() + 2);
  return `Archived ${fmt(from)}. Its dose history and batch number stay in your encrypted ` +
    `data until ${fmt(until)}, then counta.click deletes the record automatically.`;
}

function enterDoseMode() {
  const d = pen();
  $("setup-card").hidden = true;
  $("dose-card").hidden = false;
  buildSwitcher();
  showBack(false);
  renderHistory();

  const archived = !!d.archivedOn;
  $("dose-entry").hidden = archived;
  $("archived-note").hidden = !archived;
  $("unarchive-pen").hidden = !archived;
  $("export-ics").hidden = archived;
  $("edit-pen").hidden = archived;
  $("trash-pen").hidden = !archived;
  $("archive-pen").hidden = true;
  if (archived) {
    $("archived-note-text").textContent = archivedCopy(d);
    paintPen();
  } else {
    doseClicks = d.common.length ? clicksFor(d.common[0]) : Math.min(8, d.totalClicks);
    $("f-date").value = todayISO();
    buildChips();
    renderDose();
  }
}

async function setArchived(flag) {
  pen().archivedOn = flag ? todayISO() : null;
  try {
    await persistPen(activePen);
  } catch (e) {
    pen().archivedOn = flag ? null : todayISO();
    alert("Couldn’t update the pen: " + e.message);
    return;
  }
  editingPen = null;
  enterDoseMode();
  announce(flag ? "Pen archived. Its history is kept for 2 years." : "Pen unarchived.");
}

/* ============ pen svg (ported; hooks per counta-pen.svg header) ============ */
const svg = () => $("pen-svg");
function paintPen() {
  const d = pen();
  if (!d) return;
  const s = svg();
  for (const [ k, v ] of Object.entries(d.theme)) s.style.setProperty(k, v);
  const n = s.querySelector("#product-name");
  n.textContent = d.name || "My pen";
  n.removeAttribute("textLength");
  if (n.getComputedTextLength() > 118) {
    n.setAttribute("textLength", 118);
    n.setAttribute("lengthAdjust", "spacingAndGlyphs");
  }
  s.querySelector("#product-strength").textContent = d.strength;
  s.querySelector("#label-batch").textContent = "LOT " + (d.batch || "—");
  s.querySelector("#label-expiry").textContent = "EXP " + (d.expiry ? d.expiry.slice(5, 7) + "/" + d.expiry.slice(0, 4) : "—");
  const f = d.totalClicks ? remainingClicks() / d.totalClicks : 1;
  s.querySelector("#piston-assembly").style.transform = `translateY(${(1 - f) * PISTON_TRAVEL}px)`;
  // progress-style windows show no readable number (docs/design-notes.md) —
  // drawing one on the graphic would imply the window shows the dose.
  s.querySelector("#dose-value").textContent =
    d.counterStyle === "progress" || d.archivedOn ? "" : fmtU(unitsForClicks(doseClicks));
}
function showBack(back) {
  svg().classList.toggle("show-back", back);
  $("pen-caption").textContent = back ? "Back of pen — batch & expiry" : "Front of pen";
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

function clampDose() {
  const max = Math.min(pen().maxDialClicks, remainingClicks() || pen().maxDialClicks);
  doseClicks = Math.max(1, Math.min(doseClicks, max === 0 ? 1 : max));
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
  $("readout-big").textContent = doseClicks + (doseClicks === 1 ? " click" : " clicks");
  $("readout-sub").textContent = d.counterStyle === "progress"
    ? `≈ ${fmtU(u)} ${d.unit} · the window shows no number — your click count is the dose`
    : `counter will show ${fmtU(u)}`;
  [ ...$("chips").children ].forEach((b, i) =>
    b.setAttribute("aria-pressed", clicksFor(d.common[i]) === doseClicks));
  // A finished or expired pen suggests archiving rather than trashing —
  // archiving keeps its history and batch number.
  $("archive-pen").hidden = !(remainingClicks() === 0 || isExpired(d));
  renderStatsWarnings();
  paintPen();
}

function renderStatsWarnings() {
  const d = pen();
  const rc = remainingClicks(), ru = unitsForClicks(rc);
  const rd = remainingDoses();
  const ml = d.capMl ? ` · ${(d.capMl * rc / d.totalClicks).toFixed(2)} mL` : "";
  $("stats").innerHTML =
    `<div class="stat"><div class="v">${fmtU(ru)}</div><div class="k">${d.unit} left${ml ? "" : ""}</div></div>` +
    `<div class="stat"><div class="v">${rd}</div><div class="k">doses left</div></div>` +
    `<div class="stat"><div class="v">${rc}</div><div class="k">clicks left</div></div>`;
  const w = [];
  const today = new Date(todayISO());
  if (d.expiry) {
    const expEnd = new Date(+d.expiry.slice(0, 4), +d.expiry.slice(5, 7), 0); // last day of expiry month
    if (expEnd < today) {
      w.push([ "red", `This pen expired ${d.expiry.slice(5, 7)}/${d.expiry.slice(0, 4)}.` ]);
    } else if (rd > 0) {
      const runout = new Date(today);
      runout.setDate(runout.getDate() + Math.ceil(rd * d.freqDays));
      if (runout > expEnd) {
        const dosesByExp = Math.floor((expEnd - today) / (864e5 * d.freqDays));
        w.push([ "amber", `Heads-up: at every ${d.freqDays} day${d.freqDays > 1 ? "s" : ""}, you’ll only fit ~${dosesByExp} more dose${dosesByExp === 1 ? "" : "s"} before expiry (${d.expiry.slice(5, 7)}/${d.expiry.slice(0, 4)}) — ${rd} doses remain in the pen.` ]);
      }
    }
  }
  if (rc === 0) w.push([ "red", "This pen is empty." ]);
  else if (rd <= 1) w.push([ "amber", rd === 1 ? "Running out: last full dose in this pen." : "Not enough left for a full dose." ]);
  $("warnings").innerHTML = w.map(([ c, t ]) =>
    `<div class="warn ${c}"><span aria-hidden="true">${c === "red" ? "⛔" : "⚠️"}</span><span>${t}</span></div>`).join("");
}

function renderHistory() {
  const ul = $("history");
  const h = pen().history;
  if (!h.length) {
    ul.innerHTML = '<li class="empty">No doses yet</li>';
    return;
  }
  const short = iso => new Date(iso + "T00:00").toLocaleDateString(undefined, { day: "numeric", month: "short" });
  ul.innerHTML = h.slice(-5).reverse().map(e =>
    `<li><span>${short(e.date)}</span><span><strong>${e.clicks} clicks</strong> <span class="mgv">≈ ${fmtU(e.units)} ${pen().unit}</span></span></li>`).join("");
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
      showError("landing-error", e);
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
    showError(errEl, e instanceof PrfUnsupportedError ? e :
      new Error("Sign-in didn’t complete. " + (e.message || e)));
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
    announce("Recovered. Consider adding a passkey from the account panel.");
  } catch (e) {
    showError("rec-error", e.status === 401
      ? new Error("That account ID and kit don’t match.") : e);
  }
}

/* ============ account panel ============ */
async function openAccountPanel() {
  clearError("account-error");
  $("acct-id").textContent = accountId;
  const creds = await api("/api/credentials");
  $("passkey-list").innerHTML = creds.map((c, i) =>
    `<li><span>Passkey ${i + 1}</span><span class="mgv">added ${new Date(c.created_at).toLocaleDateString()}</span></li>`).join("");
  show("account-screen");
}

/* ============ ICS export ============ */
function downloadIcs() {
  const d = pen();
  const ics = buildIcs(d, activePen.id, remainingDoses(), doseClicks,
    `${fmtU(unitsForClicks(doseClicks))} ${d.unit}`);
  if (!ics) {
    alert("Nothing left to schedule for this pen.");
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
    await api("/device/flush", { method: "POST" });
    announce("Push data for this device cleared.");
    alert("Any push data this device created on the server has been removed.");
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
      showError("rec-error", new Error("That file doesn’t look like a counta recovery kit."));
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
    if (d.productKey === "custom") $("f-name").value = d.name;
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
    $("confirm-clicks").textContent = doseClicks + (doseClicks === 1 ? " click" : " clicks");
    const dte = $("f-date").value || todayISO();
    $("confirm-mg").textContent = `≈ ${fmtU(unitsForClicks(doseClicks))} ${pen().unit} · ${dte === todayISO() ? "today" : dte}`;
    $("confirm-dlg").showModal();
  });
  $("confirm-yes").addEventListener("click", async () => {
    $("confirm-dlg").close();
    const entry = { date: $("f-date").value || todayISO(), clicks: doseClicks, units: unitsForClicks(doseClicks) };
    pen().history.push(entry);
    try {
      await persistPen(activePen);
    } catch (e) {
      pen().history.pop(); // not saved — don't show it as if it were
      alert("Couldn’t save that dose: " + e.message);
      return;
    }
    renderHistory();
    renderDose();
    buildSwitcher(); // % remaining in the switcher label stays live
    announce(`Dose recorded: ${doseClicks} clicks. ${remainingClicks()} clicks remain.`);
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
      alert("Couldn’t trash the pen: " + e.message);
      return;
    }
    pens = pens.filter(p => p !== activePen);
    editingPen = null;
    activePen = pens.find(p => !p.data.archivedOn) || pens[0] || null;
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
      announce("Passkey added.");
    } catch (e) {
      showError("account-error", e instanceof PrfUnsupportedError ? e : e);
    }
  });
  $("delete-account").addEventListener("click", () => $("delete-dlg").showModal());
  $("delete-no").addEventListener("click", () => $("delete-dlg").close());
  $("delete-yes").addEventListener("click", async () => {
    $("delete-dlg").close();
    try {
      await deleteAccount();
    } catch (e) {
      showError("account-error", e);
      return;
    }
    dek = null;
    accountId = null;
    pens = [];
    activePen = null;
    show("landing-screen");
    announce("Account and all data deleted.");
  });
}

/* ============ test hooks ============ */
// Used by the system specs to prove the envelope end-to-end without going
// through the pen UI. Harmless in production: every call still requires an
// unlocked session (dek in memory).
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
  // Exact string the ICS download would contain (same code path).
  icsPreview() {
    const d = pen();
    return buildIcs(d, activePen.id, remainingDoses(), doseClicks,
      `${fmtU(unitsForClicks(doseClicks))} ${d.unit}`);
  }
};

/* ============ boot ============ */
wire();
if (document.querySelector('meta[name="signed-in"]').content === "true") {
  show("unlock-screen");
} else {
  show("landing-screen");
}
