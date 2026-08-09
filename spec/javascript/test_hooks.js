// Test-only hooks. Imported dynamically, and only when the test-hooks meta tag
// is present — which the layout emits in the test environment alone. This
// module isn't pinned outside test either, so a real browser never fetches or
// parses it. Previously all of this shipped to every user and only the
// *assignment* was gated, which made the comment claiming otherwise false.
//
// It needs app.js's private state, above all the DEK. app.js passes that in as
// an explicit context built inside the same gate, rather than exporting it —
// so there's no general-purpose escape hatch for anything else to reach.
//
// Note the context is GETTERS, not values: `dek` is null at boot and only set
// on unlock, so capturing it once would leave every hook holding null forever.
import { roundToNearestHalfHour } from "dosing_time";
import { stepIndexFor, daysBetween, missedDosesSince, planStepError,
         nextDoseStep, dosesLeftAtStep, reachableSteps, priorDosesFor } from "plan";

export function install(ctx) {
  const { api, encryptPayload, decryptPayload, buildIcsForExport } = ctx;
  const dek = () => ctx.dek();

  async function currentRow() {
    const [ row ] = await api("/api/pens");
    return row;
  }

  // Rewrites the stored pen as another device would: at the row's current
  // version, so the write succeeds and this tab's cached version goes stale.
  async function writeAsOtherDevice(row, data) {
    return api(`/api/pens/${row.id}`, { method: "PUT", body: {
      blob: await encryptPayload(dek(), data),
      archived: row.archived_at != null,
      expected_updated_at: row.updated_at
    } });
  }

  window.countaTest = {
    unlocked: () => ctx.dek() !== null,
    accountId: () => ctx.accountId(),

    async encryptProbe(text) {
      const blob = await encryptPayload(dek(), { v: 1, probe: text });
      const res = await api("/api/pens", { method: "POST", body: { blob } });
      return res.id;
    },
    async decryptProbe() {
      const rows = await api("/api/pens");
      if (!rows.length) throw new Error("no pens");
      return (await decryptPayload(dek(), rows[0].blob)).probe;
    },

    // A second device logs a dose — the stale-tab situation, produced through
    // the real API rather than by faking a 409.
    async simulateOtherDevice(dateISO) {
      const row = await currentRow();
      const data = await decryptPayload(dek(), row.blob);
      const perClick = data.capUnits / data.totalClicks;
      data.history.push({ id: crypto.randomUUID(), date: dateISO, clicks: 8, units: 8 * perClick });
      await writeAsOtherDevice(row, data);
      return data.history.length;
    },

    // Appends a dose straight to the stored pen, for tests that need many.
    async appendDose(date) {
      const row = await currentRow();
      const data = await decryptPayload(dek(), row.blob);
      data.history.push({ id: crypto.randomUUID(), date, clicks: 1,
                          units: data.capUnits / data.totalClicks });
      await writeAsOtherDevice(row, data);
      return data.history.length;
    },

    rows: () => api("/api/pens"),
    decryptRow: row => decryptPayload(dek(), row.blob),

    async writeRow(_row, data) {
      return writeAsOtherDevice(await currentRow(), data);
    },

    // writeRow always targets the first row; specs with several pens need to
    // say which one.
    async writeRowAt(index, data) {
      const rows = await api("/api/pens");
      return writeAsOtherDevice(rows[index], data);
    },
    async decryptRowAt(index) {
      const rows = await api("/api/pens");
      return decryptPayload(dek(), rows[index].blob);
    },

    // Another device archives the pen; this tab's cached state stays stale.
    async archiveElsewhere() {
      const row = await currentRow();
      return api(`/api/pens/${row.id}`, { method: "PUT", body: {
        blob: row.blob, archived: true, expected_updated_at: row.updated_at
      } });
    },

    async historyFromServer() {
      const row = await currentRow();
      return (await decryptPayload(dek(), row.blob)).history;
    },

    // Exact string the ICS download would contain (same code path) — mints
    // calendarUid / bumps calendarSequence and persists them, exactly like a
    // real export. `nowMs` (epoch ms), if given, pins the "moment of export"
    // the dosing-time proxy rounds, so specs can assert exact DTSTART/DTEND
    // without racing the real clock.
    icsPreview(nowMs) {
      // Capybara marshals a missing/nil arg as JS `null`, not `undefined` —
      // treat both as "use the real clock" so buildIcsForExport's own
      // `now = new Date()` default still applies.
      return buildIcsForExport(nowMs == null ? undefined : new Date(nowMs));
    },

    // The active pen's plan as stored (issue #21), and the derived number the
    // dose screen shows — "doses left at this step" once a plan exists.
    plan: () => ctx.pen()?.plan ?? null,

    // Appends a dose to a SPECIFIC pen row, as another device would. The
    // single-pen appendDose above always targets the first row, which can't
    // express "a dose on the insulin pen must not advance the Wegovy ladder".
    async appendDoseTo(index, date, clickCount) {
      const rows = await api("/api/pens");
      const row = rows[index];
      const data = await decryptPayload(dek(), row.blob);
      data.history.push({ id: crypto.randomUUID(), date, clicks: clickCount,
                          units: clickCount * data.capUnits / data.totalClicks });
      await api(`/api/pens/${row.id}`, { method: "PUT", body: {
        blob: await encryptPayload(dek(), data),
        archived: row.archived_at != null,
        expected_updated_at: row.updated_at
      } });
      return data.history.length;
    },

    // plan.js's pure derivations, probed directly. They are integer/string
    // arithmetic with no DOM and no I/O, so exercising the edge cases here is
    // both exact and far cheaper than driving each one through the UI.
    planStepIndex: (steps, n) => stepIndexFor({ steps }, n),
    // Positions a person can claim to be on. The shipped ladder ends
    // open-ended, so the filter is a no-op there and only a hand-written
    // ladder with an open-ended step in the MIDDLE exercises it.
    planReachableSteps: steps => reachableSteps(steps).length,
    planPriorDosesFor: (steps, index, atStep) => priorDosesFor(steps, index, atStep),
    // All three branches of the step validator, including the null
    // maxDialClicks one (a custom pen's dial limit is unknown, not
    // unlimited), which no listed product can reach through the UI today.
    planStepError: (units, maxDialClicks, unitsPerClick) =>
      planStepError({ units }, { clicksFor: u => Math.round(u / unitsPerClick), maxDialClicks }),
    // A completed finite ladder has nothing further to offer: stepIndexFor
    // holds at the last step, so without the `complete` flag the boundary
    // check can never fire and the count runs on until the pen empties.
    planDosesLeftAt: (steps, taken, remainingClicks, unitsPerClick) => {
      const plan = { id: "probe", startedOn: "2000-01-01", steps };
      const pens = [ { data: { plan, history: Array.from({ length: taken },
        (_, i) => ({ id: String(i), date: "2020-01-01", clicks: 1 })) } } ];
      return {
        left: dosesLeftAtStep(plan, pens, {
          clicksFor: u => Math.round(u / unitsPerClick), remainingClicks
        }),
        complete: nextDoseStep(plan, pens)?.complete ?? null
      };
    },
    planDaysBetween: (fromISO, toISO) => daysBetween(fromISO, toISO),
    planMissedDoses: (lastISO, todayISO, freqDays) =>
      missedDosesSince(lastISO, todayISO, freqDays),

    // The dosing-time proxy itself (#14, reused by #37): rounds `nowMs`
    // (epoch ms) to the nearest half hour, local wall-clock, and returns the
    // result as epoch ms.
    roundToNearestHalfHour(nowMs) {
      return roundToNearestHalfHour(new Date(nowMs)).getTime();
    }
  };
}
