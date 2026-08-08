// Client-generated ICS export (docs/data-privacy.md "Reminders"): a download,
// never a hosted subscription URL — the schedule must not pass through the
// server. Deterministic UIDs per pen so a re-export replaces cleanly.

import { t, clicks } from "i18n";
import { roundToNearestHalfHour } from "dosing_time";

function pad(n) { return String(n).padStart(2, "0"); }

function icsDate(d) {
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
}

// Floating local time: no "Z", no TZID. A dose reminder set for 18:00 has to
// keep reading 18:00 across a DST transition, which a UTC instant would
// silently shift (AGENTS.md §9.6) and which most calendar clients render in
// the viewer's own zone anyway.
function icsDateTime(d) {
  return `${icsDate(d)}T${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

function escapeText(s) {
  return String(s).replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\n/g, "\\n");
}

// pen: decrypted pen data; penId: server row id, used only as a UID fallback
// for pens that predate calendarUid (see below). now: the moment export was
// pressed — a parameter rather than an inline `new Date()` so callers (and
// tests) can pin it; defaults to "actually now" for real exports.
// Returns null if there is nothing left to schedule.
export function buildIcs(pen, penId, remainingDoses, doseClicks, doseUnitsLabel, now = new Date()) {
  if (remainingDoses < 1) return null;

  // Doses can be backdated, so the last ENTERED dose isn't the latest one.
  // Anchoring on entry order put the whole series (and the refill event) a
  // cycle early — sort before taking the most recent date.
  const dates = pen.history.map(h => h.date).sort();
  const last = dates.length ? dates[dates.length - 1] : null;
  const start = last ? new Date(last + "T00:00") : new Date();
  if (last) start.setDate(start.getDate() + Math.round(pen.freqDays));

  // The dosing-time proxy (#14): no "what time do you dose?" question (that
  // would cost a screen — AGENTS.md §2's "trivially easy" rule), so the
  // moment of export stands in, rounded to the nearest half hour. Only the
  // hour/minute come from the rounded instant — its own calendar date is
  // irrelevant, since the reminder's date already comes from the dose
  // schedule above, not from "now".
  const proxyTime = roundToNearestHalfHour(now);
  start.setHours(proxyTime.getHours(), proxyTime.getMinutes(), 0, 0);
  const end = new Date(start.getTime() + 5 * 60 * 1000);

  const wholeDays = Number.isInteger(pen.freqDays);
  // DTSTAMP is a real UTC instant per RFC 5545 — building it from the local
  // calendar date and suffixing "Z" put it on the wrong day for anyone whose
  // local date differs from UTC's.
  const stamp = new Date().toISOString().replace(/[-:]|\.\d{3}/g, "");
  // calendarUid/calendarSequence live in the pen's own encrypted blob —
  // minted/incremented by the caller before this runs — rather than being
  // derived from the server row id, so a pen recreated from a preserved blob
  // keeps superseding its own old events instead of leaving them orphaned,
  // and every re-export carries a fresh SEQUENCE (RFC 5545 §3.8.7.4) so a
  // client isn't free to ignore the update. See #14 "Re-export shouldn't
  // duplicate". penId is only a fallback for pens saved before calendarUid
  // existed.
  const uidSuffix = pen.calendarUid || penId;
  const sequence = pen.calendarSequence || 0;
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
  const summary = escapeText(t(
    pen.counterStyle === "progress" ? "ics.summary_progress" : "ics.summary_numeric",
    { name: pen.name, clicks: clicks(doseClicks), units: doseUnitsLabel }
  ));
  lines.push(
    "BEGIN:VEVENT",
    `UID:counta-${uidSuffix}-dose@counta.click`,
    `SEQUENCE:${sequence}`,
    `DTSTAMP:${stamp}`,
    `DTSTART:${icsDateTime(start)}`,
    `DTEND:${icsDateTime(end)}`
  );
  if (wholeDays) {
    lines.push(`RRULE:FREQ=DAILY;INTERVAL=${pen.freqDays};COUNT=${remainingDoses}`);
  } else {
    // Fractional frequency (e.g. 3.5 days = twice a week): hourly interval.
    lines.push(`RRULE:FREQ=HOURLY;INTERVAL=${Math.round(pen.freqDays * 24)};COUNT=${remainingDoses}`);
  }
  lines.push(
    `SUMMARY:${summary}`,
    `DESCRIPTION:${escapeText(t("ics.description"))}`,
    // Fires at event time. Some clients silently drop an alarm missing
    // ACTION or DESCRIPTION, so both are set explicitly rather than relying
    // on TRIGGER alone.
    "BEGIN:VALARM",
    "ACTION:DISPLAY",
    `DESCRIPTION:${summary}`,
    "TRIGGER:PT0M",
    "END:VALARM",
    "END:VEVENT"
  );

  // "Buy more" lands ~2 doses before run-out (or on the last dose for tiny
  // remainders). It's a nudge for the week, not a moment, so it stays all-day.
  const refillIndex = Math.max(0, remainingDoses - 2);
  const refill = new Date(start);
  refill.setDate(refill.getDate() + Math.round(refillIndex * pen.freqDays));
  lines.push(
    "BEGIN:VEVENT",
    `UID:counta-${uidSuffix}-refill@counta.click`,
    `SEQUENCE:${sequence}`,
    `DTSTAMP:${stamp}`,
    `DTSTART;VALUE=DATE:${icsDate(refill)}`,
    `SUMMARY:${escapeText(t("ics.refill", { name: pen.name }))}`,
    "END:VEVENT",
    "END:VCALENDAR"
  );
  return lines.join("\r\n") + "\r\n";
}
