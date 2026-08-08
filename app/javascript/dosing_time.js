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
