// The "dosing time" proxy: when the user has never been asked what time they
// dose (asking would cost a screen — AGENTS.md §2's "trivially easy" rule),
// the moment they press an action that implies dosing (export today, and the
// #37 next-dose forecast tomorrow) stands in for it. Kept as its own function,
// not inlined into ics.js, so #37 calls this instead of re-deriving the same
// rounding rule a second time (see issue #14).
//
// Rounds to the NEAREST half hour: 17:47 -> 18:00, 17:44 -> 17:30. Ties round
// up (17:15 -> 17:30, 17:45 -> 18:00), matching the 17:47 -> 18:00 example in
// the issue. Operates on LOCAL wall-clock fields (getHours/getMinutes, not
// getTime()/UTC), so it rolls over hours/days the same way a person reading a
// clock would, and is agnostic to the surrounding date — see AGENTS.md §9.6:
// no UTC-instant arithmetic standing in for local wall-clock time.
export function roundToNearestHalfHour(date) {
  const rounded = new Date(date);
  rounded.setSeconds(0, 0);
  const minutes = rounded.getMinutes();
  const remainder = minutes % 30;
  rounded.setMinutes(remainder < 15 ? minutes - remainder : minutes - remainder + 30);
  return rounded;
}

const pad = n => String(n).padStart(2, "0");

// The rounded local wall-clock time as "HH:MM", for storing against a dose.
//
// A wall-clock string, deliberately, not an instant: "18:00" is what the
// person's routine is, and it stays 18:00 across a daylight-saving change and
// across a move to another timezone. An instant would silently become 17:00 or
// 19:00 (AGENTS.md §9.6), which is exactly the mistake #14 avoided in the ICS
// by using floating local time.
export function captureDosingTime(now) {
  const rounded = roundToNearestHalfHour(now);
  return `${pad(rounded.getHours())}:${pad(rounded.getMinutes())}`;
}

// The most recent dose that actually carries a time, or null.
//
// Entries predate the field, and backdated ones never get one (a dose entered
// for last Tuesday was not taken at this moment), so the newest entry is often
// not the one to read. Sorted by date because doses are appended in entry
// order, not date order.
export function lastDoseTime(entries) {
  const byDate = [ ...(entries ?? []) ].sort((a, b) => a.date.localeCompare(b.date));
  for (let i = byDate.length - 1; i >= 0; i--) {
    if (byDate[i].time) return byDate[i].time;
  }
  return null;
}

// THE dosing time, for every surface that needs one — the on-screen forecast
// and the calendar export both call this, which is what #37 means by the two
// never disagreeing. Best available source first:
//
//   1. the time of the last dose that recorded one — an actual observation of
//      when this person doses;
//   2. otherwise the moment they are here now, rounded — the original #14
//      proxy, on the reasoning that people interact with counta around their
//      dosing routine.
//
// Callers choose which entries to offer (the forecast can see every pen on a
// plan; an export sees its own pen), but the rule for turning them into a time
// lives only here.
export function dosingTime(entries, now) {
  return lastDoseTime(entries) ?? captureDosingTime(now);
}
