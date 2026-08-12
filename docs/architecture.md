# Architecture — why the code looks like this

The other docs cover *what* was decided and *where* the boundaries are. This
one covers **why the code is shaped the way it is**: the handful of decisions
that are expensive to reverse, and the places where the implementation looks
odd until you know the constraint it's serving.

Read it before proposing a change to the crypto, the pen data model, or
anything that renders a number about medication.

| Doc | What it's for |
|---|---|
| [`data-privacy.md`](data-privacy.md) | The decisions themselves — crypto design, the data map of what may be plaintext, the threat model, retention policy. **Authority.** |
| [`design-notes.md`](design-notes.md) | UI/UX decisions — dose entry, counter-style copy, the pen graphic. **Authority.** |
| [`repo-map.md`](repo-map.md) | Surfaces, trust boundaries, and the risk register. |
| [`ui-tour.md`](ui-tour.md) | What each screen looks like and does. |
| this file | Why the code implements those decisions the way it does. |

Where this file and an authority doc disagree, the authority doc wins and this
one is the bug.

## The one-paragraph version

Counta counts the clicks you dial on a measured-dose pen. An account is an
anonymous UUID with no email, name or password; you sign in with a passkey.
That passkey also produces the encryption key: everything about your pens and
doses is encrypted in your browser, and the server stores ciphertext it has no
way to open. Losing every passkey *and* the recovery kit means losing the data
— the deliberate cost of the operator being unable to read it.

## Decision 1 — Passkey PRF, and no passphrase fallback

Each passkey's WebAuthn PRF output goes through HKDF into a key-encrypting key,
which wraps a per-account data key (the DEK). The DEK encrypts pen blobs with
AES-256-GCM. The server holds one wrapped DEK per credential, plus one wrapped
by the recovery kit.

**Why no fallback.** A passphrase would be the weakest link and would
reintroduce exactly the guessable secret passkeys remove. So PRF is a hard
requirement, and an authenticator without it is refused at signup with copy
steering toward a platform passkey.

**Non-obvious things a reader will trip on:**

- Registration is `create()` **plus an immediate local `get()`**. PRF can only
  be evaluated during an assertion, and that output never goes near the server.
- `prf.enabled` from `create()` is a fast path, never proof — real providers
  report it inconsistently (1Password on iOS did, in testing). Only an
  assertion that yields no PRF output means "unsupported".
- Enrolling a second passkey for the same account on the **same** authenticator
  replaces the first, because resident credentials are keyed by
  (rpId, userHandle). Server credential rows and authenticator credentials are
  not 1:1 (AGENTS.md §9.1).
- The all-zero HKDF salt is deliberate and sound: RFC 5869 permits it, and both
  inputs are already uniformly random. Domain separation lives in the `info`
  strings, which is what keeps the server-visible recovery proof independent of
  the recovery wrapping key.

`spec/system/crypto_envelope_spec.rb` proves the whole envelope against real
Chromium and a virtual authenticator: register → unlock → add a second passkey
→ recover from the kit → decrypt, asserting at each step that the server holds
only ciphertext.

## Decision 2 — One encrypted blob per pen, not a row per dose

Row counts and timestamps are themselves health data: with a row per dose, the
number of rows and their spacing reconstructs someone's dosing rhythm even if
every field is encrypted. A blob per pen makes logging a dose indistinguishable
from any other write.

Two consequences follow, and both are load-bearing:

- **Ciphertext length would leak the same thing.** AES-GCM output is plaintext
  plus 16 bytes, and the payload grew ~138 bytes per dose — so `length(blob)`
  estimated the dose count from a database dump. Payloads are padded to 4 KiB
  buckets before encryption (trailing whitespace inside the JSON, which
  `JSON.parse` ignores, so nothing needed migrating).
- **A write carries the whole dose log**, so a stale client would overwrite all
  of it. Writes state the version they were based on; the server rejects a
  superseded write with 409 and returns the winning row, and the client merges
  the two histories before retrying once. The compare and the write happen
  under `SELECT … FOR UPDATE`, because checking and then writing leaves a
  window where two clients both pass the check.

Doses carry a stable id for that merge: two identical doses on the same day are
otherwise indistinguishable from the same dose seen twice. Entries predating
ids fall back to a content signature, and the merge is a multiset — for each
key it keeps whichever side has more occurrences — so a genuine repeat isn't
deleted as a duplicate.

## Decision 3 — Clicks are canonical; units are derived display

Some pens don't map one click to one dose unit — a Tresiba U200 delivers 2 U
per click. So the data model stores **clicks**, derives milligrams or units for
display, and the readout leads with clicks: the thing you physically do to the
pen.

Products carry a `counter_style`, and it governs wording everywhere:

- `numeric` — the pen's window shows a real number, so copy says "counter will
  show 12".
- `progress` — the window is a blank scroll between 0 and full (Wegovy), so the
  click count is the *only* measure and copy must never imply otherwise. The
  pen graphic's counter window is deliberately blank for these.

This is where the most dangerous defect found in review lived: the calendar
export said "counter set to N **clicks**" for every pen, which on a Tresiba
invites dialling until the window reads the click count — half the intended
dose. Exported text is read months later with the app nowhere in sight, so it
now branches on `counter_style` and states what the window will actually show.

**Anything that renders a number about medication is in this blast radius.**
Check `counter_style` before writing such copy, and check the arithmetic
against a pen whose click ratio isn't 1:1.

**The one deliberate exception: a dose plan stores units, not clicks.** Clicks
are canonical for what *happened*, because a click is a thing you did to one
specific pen. A titration ladder (`app/javascript/plan.js`, issue #21) is
*intent*, and intent has to survive moving to a different pen — often a
different strength, with a different clicks-per-unit ratio. A plan holding
clicks would silently change the dose the moment the pen changed: 74 clicks is
2.4 mg on a 9.6 mg pen and 1.2 mg on a 4.8 mg one. So plan steps are
denominated in the medicine's units and converted through the *active* pen's
own `clicksFor` at render time. That one choice is why the same code serves
someone swapping a pen per strength, someone dialling a 2.4 mg pen down to a
microdose, and someone halving a mid-strength pen.

Two consequences worth knowing before touching that module. It derives the
current step by **counting doses**, not by the calendar, so a gap can never
escalate anyone — the conservative reading is structural rather than a rule
that could have a bug. And it **stops forecasting at a step boundary**:
costing the next step against this pen's ratio would assume a pen we know
nothing about until SKUs are modelled (issue #19), so "doses left" on a
planned pen means "at this amount" and the label says so.

`plan.js#penDoseSegments` sits next to that second rule and appears to break
it — it walks the whole ladder. It does not, and the difference is worth
holding onto, because a reader will eventually try to collapse the two.
`dosesLeftAtStep` answers "how many doses at THIS amount", where walking on
means costing a step against a pen we have not seen. `penDoseSegments` answers
"what does THIS pen have left to give", and every dose it describes is
delivered by the pen in front of the user, whose ratio is right here. The
calendar export is what needed the second question: `calendarUid` lives in the
pen's own blob, so an exported series only ever describes one pen, and the next
pen mints its own. #19 is about what the *next* pen holds, and nothing in that
walk asks it.

## Decision 4 — The server owns every date

Dates cross the wire as UTC ISO 8601; the browser only formats them for the
viewer. Deadlines are computed server-side with ActiveSupport.

This followed a bug where the browser computed a retention deadline and
`toISOString()` shifted it a day for anyone off UTC. Archive state is a
server-stamped `archived_at`; the two-year deadline is derived from it and
never stored; the client sends only an intent. Re-saving an archived pen can't
restart the clock.

The exception is a **user-entered dose date**, which is a local calendar date
living inside the encrypted blob — build those from local getters, never
`toISOString()`.

Related: the UI emits `<time datetime>` alongside the human-readable date, so
tests assert a machine-readable instant rather than locale-formatted text.

## Decision 5 — Owner scoping is the tenancy boundary

Every pen read and write goes through `current_account.pens`; a cross-account
ID gets a 404. This is R-001, with a regression spec and a positive control.

The only unscoped path that touches pen data is the retention sweep, which has
no requesting user — that's R-004, and it selects purely on the plaintext
archive marker, never on ciphertext.

## What isn't built

Deliberate stopping points, each tracked as an issue rather than hidden. The
UI says so where a user could otherwise assume otherwise:

- **Pen registry / recall matching** — table migrated, matching and push not
  built.
- **Push notifications** — the device-flush endpoint is a stub.
- **Idle-account deletion** — policy decided, nothing built.
- **A scheduler** — the retention sweep is best-effort, running when someone
  lists their pens; it is not described as "automatic" anywhere.
- **Rate limiting** (R-003) and **backups** — hence no backup-retention promise
  in the delete dialog.

See the [issue list](https://github.com/abradner/counta/issues) for the current
state; this section is orientation, not a status board.
