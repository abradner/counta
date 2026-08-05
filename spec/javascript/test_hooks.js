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
export function install(ctx) {
  const { api, encryptPayload, decryptPayload, buildIcs } = ctx;
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

    // Exact string the ICS download would contain (same code path).
    icsPreview() {
      const d = ctx.pen();
      const clicks = ctx.doseClicks();
      return buildIcs(d, ctx.activePen().id, ctx.remainingDoses(), clicks,
        `${ctx.fmtU(ctx.unitsForClicks(clicks))} ${d.unit}`);
    }
  };
}
