// Client-generated ICS export (docs/data-privacy.md "Reminders"): a download,
// never a hosted subscription URL — the schedule must not pass through the
// server. Deterministic UIDs per pen so a re-export replaces cleanly.

function pad(n) { return String(n).padStart(2, "0"); }

function icsDate(d) {
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
}

function escapeText(s) {
  return String(s).replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\n/g, "\\n");
}

// pen: decrypted pen data; penId: server row id (stable per pen).
// Returns null if there is nothing left to schedule.
export function buildIcs(pen, penId, remainingDoses, doseClicks, doseUnitsLabel) {
  if (remainingDoses < 1) return null;

  const last = pen.history.length ? pen.history[pen.history.length - 1].date : null;
  const start = last ? new Date(last + "T00:00") : new Date();
  if (last) start.setDate(start.getDate() + Math.round(pen.freqDays));

  const wholeDays = Number.isInteger(pen.freqDays);
  const stamp = icsDate(new Date()) + "T000000Z";
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//counta.click//counta//EN",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH"
  ];

  // One recurring event covers every remaining dose; COUNT shrinks on
  // re-export as doses are logged, and the fixed UID replaces the old series.
  //
  // The wording must follow counter_style exactly as the in-app readout does
  // (docs/design-notes.md). Saying "counter set to N clicks" is dangerous on a
  // numeric pen where clicks != units: on a Tresiba U200 one click is 2 U, so
  // a 12 U dose is 6 clicks, and a user dialling until the window reads 6
  // would take half their dose. This text is read months later, in a calendar,
  // without the app open — it has to stand alone.
  const summary = escapeText(
    pen.counterStyle === "progress"
      ? `Dose day — ${pen.name}: dial ${doseClicks} clicks (≈ ${doseUnitsLabel}) — the window shows no number, your click count is the dose`
      : `Dose day — ${pen.name}: dial ${doseClicks} clicks — the counter will show ${doseUnitsLabel}`
  );
  lines.push("BEGIN:VEVENT", `UID:counta-${penId}-dose@counta.click`, `DTSTAMP:${stamp}`);
  if (wholeDays) {
    lines.push(
      `DTSTART;VALUE=DATE:${icsDate(start)}`,
      `RRULE:FREQ=DAILY;INTERVAL=${pen.freqDays};COUNT=${remainingDoses}`
    );
  } else {
    // Fractional frequency (e.g. 3.5 days = twice a week): hourly interval,
    // floating local time starting 09:00.
    lines.push(
      `DTSTART:${icsDate(start)}T090000`,
      `RRULE:FREQ=HOURLY;INTERVAL=${Math.round(pen.freqDays * 24)};COUNT=${remainingDoses}`
    );
  }
  lines.push(`SUMMARY:${summary}`,
    "DESCRIPTION:Exported from counta.click. counta counts clicks\\; it isn't medical advice.",
    "END:VEVENT");

  // "Buy more" lands ~2 doses before run-out (or on the last dose for tiny remainders).
  const refillIndex = Math.max(0, remainingDoses - 2);
  const refill = new Date(start);
  refill.setDate(refill.getDate() + Math.round(refillIndex * pen.freqDays));
  lines.push(
    "BEGIN:VEVENT",
    `UID:counta-${penId}-refill@counta.click`,
    `DTSTAMP:${stamp}`,
    `DTSTART;VALUE=DATE:${icsDate(refill)}`,
    `SUMMARY:${escapeText(`Buy more ${pen.name} — current pen almost finished`)}`,
    "END:VEVENT",
    "END:VCALENDAR"
  );
  return lines.join("\r\n") + "\r\n";
}
