// Client-generated ICS export (docs/data-privacy.md "Reminders"): a download,
// never a hosted subscription URL — the schedule must not pass through the
// server. Deterministic UIDs per pen so a re-export replaces cleanly.

import { t } from "i18n";
import { dosingTime } from "dosing_time";

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

// Whole hours a fractional cadence recurs by. Rounded ONCE, here, and used both
// to write the RRULE and to step between segments — the two must be the same
// integer or they disagree about where a segment ends. Rounding the whole span
// instead (`round(doses * freqDays * 24)`) is the bug that hid here: at
// freqDays 1.1 the rule steps 26 h an occurrence, so two doses land 52 h apart,
// while the span rounds 52.8 to 53 and starts the next segment an hour late,
// compounding down the ladder. Floored at 1 because INTERVAL=0 is not a legal
// recurrence and would make the whole file unparseable.
function stepHours(freqDays) {
  return Math.max(1, Math.round(freqDays * 24));
}

// One dose reminder, `doses` occurrences apart by the pen's frequency, starting
// `from`. Whole-day cadences step by calendar days so a 25-hour day still lands
// on the right date; fractional ones (3.5 = twice weekly) step the wall clock by
// hours, matching how a floating FREQ=HOURLY rule is read (AGENTS.md §9.6).
function advance(from, doses, freqDays) {
  const d = new Date(from);
  if (Number.isInteger(freqDays)) d.setDate(d.getDate() + doses * freqDays);
  else d.setHours(d.getHours() + doses * stepHours(freqDays));
  return d;
}

function rrule(freqDays, count) {
  return Number.isInteger(freqDays)
    ? `RRULE:FREQ=DAILY;INTERVAL=${freqDays};COUNT=${count}`
    : `RRULE:FREQ=HOURLY;INTERVAL=${stepHours(freqDays)};COUNT=${count}`;
}

// pen: decrypted pen data; penId: server row id, used only as a UID fallback
// for pens that predate calendarUid (see below). now: the moment export was
// pressed — a parameter rather than an inline `new Date()` so callers (and
// tests) can pin it; defaults to "actually now" for real exports.
//
// `series` is what the caller worked out should be scheduled, already in the
// order it happens:
//
//   { events:    [ { slot, doses, summary } ],   // slot names the UID
//     cancelled: [ slot, ... ] }                 // tombstones, see below
//
// A pen with no plan passes one event on slot "dose"; a laddered one passes a
// "dose-s{n}" event per step it reaches (#45). This module does not know what a
// plan is — it lays out dates and writes RFC 5545 — so the ladder lives in
// plan.js#penDoseSegments and the copy in app.js, and neither leaks in here.
//
// Returns null if there is nothing left to schedule.
export function buildIcs(pen, penId, series, now = new Date(), entriesForTime = null) {
  const events = series?.events ?? [];
  const cancelled = series?.cancelled ?? [];
  const totalDoses = events.reduce((sum, e) => sum + e.doses, 0);
  if (totalDoses < 1) return null;

  // Doses can be backdated, so the last ENTERED dose isn't the latest one.
  // Anchoring on entry order put the whole series (and the refill event) a
  // cycle early — sort before taking the most recent date.
  const dates = pen.history.map(h => h.date).sort();
  const last = dates.length ? dates[dates.length - 1] : null;
  const start = last ? new Date(last + "T00:00") : new Date();
  if (last) start.setDate(start.getDate() + Math.round(pen.freqDays));

  // The dosing time (#14, unified with the on-screen forecast in #37): still
  // no "what time do you dose?" question — that would cost a screen (AGENTS.md
  // §2's "trivially easy" rule) — but the guess is now informed. dosingTime
  // prefers the time a dose was actually recorded at and falls back to the
  // moment of export, rounded, exactly as before. The screen calls the same
  // function, so the calendar and the forecast cannot name different times.
  //
  // Only the hour and minute are taken from it: the reminder's DATE comes from
  // the dose schedule above, never from "now".
  const [ hour, minute ] = dosingTime(entriesForTime ?? pen.history, now).split(":").map(Number);
  start.setHours(hour, minute, 0, 0);

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

  // Every event's date is measured from the ORIGINAL anchor by a running dose
  // ordinal — the same figure the refill nudge below counts back from, so the
  // two cannot disagree about where the series ends. Both branches of `advance`
  // are exact integer field arithmetic (whole calendar days, or whole hours via
  // stepHours), which is what lets the ordinal be applied in one hop instead of
  // accumulated segment by segment.
  let ordinal = 0;
  const description = escapeText(t("ics.description"));

  for (const event of events) {
    const from = advance(start, ordinal, pen.freqDays);
    const to = new Date(from);
    // Field arithmetic, not `+5*60*1000`: adding an instant to a floating local
    // time re-crosses the §9.6 hazard the rest of this file avoids.
    to.setMinutes(to.getMinutes() + 5);

    // The wording must follow counter_style exactly as the in-app readout does
    // (docs/design-notes.md). Saying "counter set to N clicks" is dangerous on
    // a numeric pen where clicks != units: on a Tresiba U200 one click is 2 U,
    // so a 12 U dose is 6 clicks, and a user dialling until the window reads 6
    // would take half their dose. This text is read months later, in a
    // calendar, without the app open — it has to stand alone. The caller builds
    // it per event, because a laddered pen says something different each step.
    const summary = escapeText(event.summary);
    lines.push(
      "BEGIN:VEVENT",
      `UID:counta-${uidSuffix}-${event.slot}@counta.click`,
      `SEQUENCE:${sequence}`,
      `DTSTAMP:${stamp}`,
      `DTSTART:${icsDateTime(from)}`,
      `DTEND:${icsDateTime(to)}`
    );
    // A one-dose segment is a plain event. The last step of a ladder is
    // routinely a single dose, and COUNT=1 makes some clients draw a recurring
    // series with one occurrence.
    if (event.doses > 1) lines.push(rrule(pen.freqDays, event.doses));
    lines.push(
      `SUMMARY:${summary}`,
      `DESCRIPTION:${description}`,
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
    ordinal += event.doses;
  }

  // Tombstones. Advancing a step stops emitting the step before it, which would
  // otherwise leave its occurrences sitting in the user's calendar forever.
  // STATUS:CANCELLED inside METHOD:PUBLISH rather than a METHOD:CANCEL message:
  // this is a downloaded file, not an iTIP exchange, and one file cannot carry
  // two METHODs. What makes a client honour it is the shared SEQUENCE above,
  // which is strictly higher than the export that created the event.
  for (const slot of cancelled) {
    lines.push(
      "BEGIN:VEVENT",
      `UID:counta-${uidSuffix}-${slot}@counta.click`,
      `SEQUENCE:${sequence}`,
      `DTSTAMP:${stamp}`,
      `DTSTART:${icsDateTime(start)}`,
      "STATUS:CANCELLED",
      "END:VEVENT"
    );
  }

  // "Buy more" lands ~2 doses before the pen stops being able to follow the
  // plan — which on a ladder is earlier than the barrel running dry, because
  // the last step it can fund usually leaves clicks stranded behind a dose it
  // can't afford. That is the right moment to nudge: you need the next pen
  // before the ladder stalls, not before the pen is empty. It's a nudge for the
  // week, not a moment, so it stays all-day.
  const refill = advance(start, Math.max(0, totalDoses - 2), pen.freqDays);
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
