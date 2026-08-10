# counta.click — data & privacy design

Status: agreed 2026-08-04 (Alex + Claude design session). Decisions marked **[decided]**; open items marked **[open]**.

## The promise

The operator can **never read your personal information**. Everything identifying or health-revealing is encrypted client-side with a key the server never holds. The server stores the minimum plaintext needed to run the service, and each plaintext field below exists for a stated reason.

## Threat model (what leaks, when)

| Scenario | What an attacker learns |
|---|---|
| DB dump (backup theft, SQLi, misconfigured replica) | Anonymous accounts (no email/name exist), activity timestamps, ciphertext blobs, the pen registry (product+batch ↔ push endpoint, **not** ↔ account), push endpoints |
| App-server compromise, read-only (traffic, memory, disk — attacker cannot change what's served) | Same as above plus live traffic; still no DEKs (PRF outputs never leave the client) |
| App-server compromise where the attacker can **change the JavaScript served** | **Everything, for every user who unlocks afterwards.** The crypto is delivered by the same server it protects against, so hostile JS can exfiltrate the PRF output and DEK at unlock. This is inherent to web-delivered E2EE and is *not* mitigated by anything in this design — only by out-of-band integrity (signed/pinned bundles, a store-delivered app). Stated plainly because the row above is easy to misread as covering it. **[corrected 2026-08-05 after review]** |
| Client/device compromise | Everything for that account — out of scope, as with any E2E app |
| Operator (Alex) | Same as DB dump. This is the point. |

No cross-account blast radius: every account has its own DEK.

## Crypto design **[decided]**

- **Auth**: WebAuthn passkeys only, discoverable credentials (usernameless login). No email, no username, no password. Account handle = random UUID.
- **PRF required**: registration feature-detects the WebAuthn PRF extension and rejects authenticators without it, with copy steering to a platform passkey. One code path, no passphrase fallback (a passphrase would reintroduce the guessable secret passkeys eliminate).
- **Envelope**: random 256-bit account DEK encrypts all sensitive payloads (AES-256-GCM). Each passkey's PRF output → HKDF → KEK → wraps the DEK; server stores one wrapped DEK per credential. PRF outputs and DEKs never leave the client.
- **Recovery kit**: a master key generated at signup, shown once (confirm-before-continue), wraps the DEK like any other credential. Lose all passkeys **and** the kit → data is gone, by design; UI must say this plainly at creation.
  - *Amended 2026-08-04 (was "words + QR + file download"):* the kit is now **file download first, 24 words behind an optional show-toggle, no QR**. Reason: a scanned QR had no consumer — phone cameras just web-search the raw payload — and leading with 24 words made the ceremony feel long; the JSON file (account ID + words) is the funnel, words remain for people who want a paper copy.
- **Adding a passkey requires an unlocked session** (the DEK must be in client memory to wrap for the new credential). The "add passkey" flow lives inside the signed-in account panel, never at login.
- Note: PRF evaluation needs an assertion — registration flow is `create()` with the PRF extension, then an immediate `get()` to obtain the PRF output for wrapping.
- Rails: `webauthn-ruby` for ceremonies; all PRF/HKDF/wrap logic is client-side WebCrypto.

## Data map

### Encrypted (inside the per-pen blob) **[decided]**
One `pens` row per pen with a single encrypted payload containing: pen details as the user sees them (product, nickname, capacity, total clicks, batch, expiry), full dose log (dose dates — including backdated — clicks, units, and for a dose recorded as today, the rounded local time of day it was recorded at), dose frequency, per-pen settings, the pen's **dose plan** (see below), and the pen's registry tokens (see below).

**Dose plans (titration ladders)** live inside that same blob, as a copy per pen carrying a shared `plan.id` and a monotonic `rev` — never in a column, and never in an account-level record. The plan is a sequence of `{units, doses}` steps plus the citation it was transcribed from. Per-pen copies rather than one account-level plan because a plan routinely spans pens (a Wegovy pen holds four doses and a step is four doses), so this way each archived pen keeps the plan it was actually used under — a free audit trail for a future prescriber export — and a formulation switch needs no modelling at all. The tradeoff, accepted: concurrent pens can hold copies edited on different devices, resolved by highest `rev` in the 409 handler. Migrating later to an account-level blob stays possible and lossless (read the highest-`rev` copy per id); the reverse would have to invent history that was never recorded. **Nothing new is plaintext:** no column, no index, no endpoint, and no "has a plan" flag — a health-status boolean would be the first plaintext health field in the system, and if a server-side feature ever needs one it goes through the opt-in `reminder_escrows` pattern above. Blob length is bucketed to 4 KiB before encryption, and a plan is a few hundred bytes, so it usually changes nothing an observer can see — but "usually" is the honest word: a blob already sitting near a bucket boundary will cross into the next one, exactly as it would from a few more doses. The guarantee the padding gives is bucket granularity, not a fixed size, and a one-bucket step is indistinguishable from ordinary history growth. **[decided 2026-08-09, issue #21]**

Why a blob, not a row per dose: row counts + timestamps would reconstruct dosing rhythm even with encrypted payloads (doses ≈ capacity ÷ rows). A blob makes logging a dose indistinguishable from any other account activity and dissolves the uuidv7-on-dose-rows question. The cost is that a write carries a pen's *whole* dose log, so a stale client would overwrite all of it — writes therefore use optimistic concurrency (the client states the version it based the write on; the server rejects with 409) and the client merges the two histories by dose id before retrying. **[amended 2026-08-05: the original "last-write-wins is fine for a single-user account" was wrong — one account routinely means several devices, and this cut ships multi-passkey support.]** A few KB even at hundreds of doses. Payloads are **padded to 4 KiB buckets before encryption** (trailing whitespace inside the JSON, which `JSON.parse` ignores, so it is backward compatible): AES-GCM ciphertext is plaintext + 16 bytes, so without padding `length(blob)` estimated the dose count straight from a database dump — the exact inference this design exists to prevent. **[closed 2026-08-05, issue #3]**

### Plaintext, with reasons **[decided]**
| Field | Where | Why plaintext |
|---|---|---|
| Account activity timestamps | `accounts.created_at/updated_at`, uuidv7 PKs | Idle-account sweep; ops hygiene. Accepted leak: "this account touched the server at T". |
| Archived-pen marker | `pens.archived_at` (timestamp, nullable) | Server-side retention sweep (`PenPurgeJob`) for archived pens — a client-side prune can't run for a user who never returns, so the 2-year claim needs a server mechanism. Server-stamped from the client's archive *intent*; the retention deadline is derived (`archived_at + Pen::ARCHIVE_RETENTION`), never stored, so there is one calculation in one place. Accepted leak: "this pen was archived at T"; nil for in-use pens. Added 2026-08-04. |
| Pen registry: `product_id`, normalized batch, expiry month | `pen_registrations` | Targeted recall push + product usage stats (below). **Not linked to accounts.** |
| Push subscription (endpoint, keys) | attached to registry rows | Recall delivery. |
| Recall list | `recalls` (public) — **not built yet, no table exists** | It's public information. |
| Passkey material | `webauthn_credentials`: `external_id`, `public_key`, `sign_count`, timestamps | WebAuthn verification needs them server-side by construction. Reveals how many passkeys an account has and when each was added; no identity, and the private key never leaves the authenticator. |
| Wrapped key material | `accounts.recovery_wrapped_dek`, `accounts.recovery_auth_digest`, `webauthn_credentials.wrapped_dek` | The envelope itself: ciphertext the server cannot open, plus a non-invertible digest used to check a recovery proof. Useless without a passkey or the kit. |
| Product reference data | `products` (public) | Powers the app's preset dropdowns AND recall matching — one table, two jobs. |

Dose frequency: **encrypted** by default (reminders ship as client-generated ICS, so the server doesn't need it). **Push dose reminders are a planned feature, not a maybe** — calendars suit desk workers; push suits everyone with a phone. They are strictly **opt-in**: opting in creates a `reminder_escrows` row (account_id, next_due_at, frequency) after an explicit tradeoff explanation; opting out deletes it. Opt-in escrow is the standing pattern for any future plaintext.

## The pen registry (recalls without an account⇄medicine map) **[decided]**

The recall driver is real: finding out your insulin is bad *as you're about to jab* is the failure mode, so recall pushes must be targeted (broadcast "maybe check your pens" notifications to unaffected users is alarm fatigue; silent web pushes are unreliable/revocation-prone on iOS). Targeted push requires server-side matching. The registry provides it **unlinkably**:

- `pen_registrations`: **uuidv4 PK** (not v7 — no embedded timestamp to correlate), `product_id`, `batch` (normalized), `expiry_month`, `push_subscription_id`, `created_on` (date only, quantized).
- **No `account_id`.** The row says "some device with push endpoint E holds Wegovy batch B", never who. The client keeps its registration IDs inside the encrypted pen blob and uses them to update/delete its rows.
- Recall flow: admin inserts recall → server matches registrations by product+batch → pushes to matched endpoints → notification deep-links to the app, which shows the affected pen from local/decrypted data.
- Product stats: `COUNT(*) GROUP BY product_id` gives "what are people actually using" and signals new market entrants (custom-pen registrations carry optional free-text product names — admin-reviewed, since free text can contain anything).
- Deletion: account deletion decrypts the blob, deletes listed registrations, then the account. Orphan sweep: purge registrations past `expiry_month` + 3 months.
- Residual risks, accepted: timing correlation between account activity and registration creation (mitigated by date-quantized `created_on`); push endpoints are vendor URLs that a platform + subpoena could tie to a device. Documented, not solved.
- Registration happens at pen setup with a visible disclosure line and a toggle (default **on** — the safety feature is the product's point, but it must be declinable). **[open: exact copy]**

## Reminders **[decided]**

Client-generated **ICS file** (download/share — not a hosted subscription URL, which would hand the schedule to a server): a recurring dose event for the remaining doses in the pen, plus a "buy more <product>" event ~2 doses before run-out. Honest caveat in UI: your calendar provider then holds your schedule — that's the user's tradeoff to make.

The dose event is a **timed 5-minute event with a `VALARM` firing at start** (issue #14), not all-day — an all-day event doesn't alert on most clients and can't carry a time. There's no "what time do you dose?" field (that would cost a screen — §2's ease-of-use principle); the moment the user presses export stands in, rounded to the nearest half hour. Times are floating local time (no `TZID`, no UTC `Z`), so a dose at 18:00 stays 18:00 across a DST transition. The refill nudge stays all-day — it's for the week, not a moment.

UIDs are per-pen but not derived from the server row id: `calendarUid` (minted once) and `calendarSequence` (incremented every export, giving RFC 5545 `SEQUENCE` so a client can't ignore an update) live inside the pen's own encrypted blob, alongside dose history. That way a pen recreated from a preserved blob keeps superseding its own old calendar events instead of leaving stale ones behind, without hashing batch/expiry into anything that lands in a third-party calendar.

## DB hygiene (Rails) **[decided]**

- Keep `created_at`/`updated_at` everywhere. They're the idle sweep, sync conflict tiebreaker, and debugging backbone; with blob-per-pen they no longer proxy dose events.
- uuidv7 PKs for `accounts`, `pens`, `webauthn_credentials` (index locality; embedded creation time is accepted activity metadata). uuidv4 **only** for `pen_registrations` (severs timing linkage).
- **No pgcrypto / server-side column encryption** (incl. Rails `encrypts`): keys would have to exist server-side at query time, which breaks "the operator can never read it" structurally. The client-side envelope already covers the stolen-disk/backup threat pgcrypto addresses; deliberate plaintext (registry, timestamps) must stay plaintext to do its job. Decided 2026-08-04.
- Indices only on what's queried. Currently: `pens.account_id`, `pens.archived_at` (retention sweep), `accounts.updated_at` (idle sweep), `webauthn_credentials.external_id` (login lookup) and `.account_id`, `pen_registrations (product_id, batch)`, `.product_id` and `.push_subscription_id` (foreign keys). Check `db/schema.rb` rather than this list when it matters.
- Ciphertext is opaque — nothing else needs indexing.

## Policies

- **Archived pens**: a finished/expired pen can be archived rather than trashed — it keeps its dose history and batch number, drops out of the pen switcher, and is reachable from the account panel. Retention is 2 years from archiving, applied server-side by `PenPurgeJob` against the server-stamped `pens.archived_at` (trashing is still immediate and total). Re-saving an archived pen must not restart the clock. **[decided 2026-08-04]**
  - *Honest status:* the sweep is **best-effort, not scheduled** — with deployment undecided there is no cron, so it runs opportunistically when someone lists their pens, plus `rake pens:purge`. A pen belonging to an account nobody opens again is not deleted on time. Don't call this "automatic" in docs or UI until a scheduler exists. **[open: scheduler]**
- **Time handling**: everything crosses the wire as UTC ISO8601 and the client only *formats* it for the viewer's zone. Dates and deadlines are calculated server-side with ActiveSupport, never in the browser — browser date arithmetic silently shifted a retention deadline by a day for a non-UTC user (AGENTS.md §9.6). The exception is a user-entered dose date, which is a local calendar date living inside the encrypted blob. **[decided 2026-08-04]**
- **Idle deletion** — **policy decided, NOT built.** No job, task or spec exists; `accounts.updated_at` is maintained and indexed ready for it, and nothing in the UI tells users the policy yet. Both must land before this can be described as in force. Accounts untouched for 2 years are deleted (defined by `accounts.updated_at`). With no plaintext contact channel there is no pre-deletion warning email — a push warning at ~23 months is possible where a subscription exists. Document the policy publicly. **[decided]**
- **Account deletion**: one panel, full cascade (account, credentials, pens, registrations via client-held IDs, escrows), one confirmation step. State the backup-retention window (suggest 30 days) after which deleted data is gone from backups too. **[open: retention window]**
- **Backups**: encrypted at rest; same access controls as prod.

## First-run & device hygiene **[decided]**

- Signup is a first-time flow, not just a passkey ceremony: (1) disclaimer acceptance — descriptive-tool framing ("counta counts clicks; it isn't medical advice") plus a plain-language summary of this data model; (2) passkey creation with PRF feature-detection and steering copy; (3) recovery-kit ceremony with the loss warning and a confirm-you-saved-it step.
- **Flush push keys without an account**: a device-level action (available from the pre-signup/landing state) that unsubscribes the browser's push subscription and calls a public endpoint deleting every server row tied to that endpoint (pen registrations, escrows). Anyone can walk away clean without ever creating an account.

## Account & data management panel (v1 scope)

Delete account & all data (with confirmation) · manage pens · view history · manage passkeys (add requires unlocked session; can't remove the last credential unless the recovery kit is confirmed) · recovery kit status/regenerate (regenerating re-wraps the DEK and invalidates the old kit).

## Worth stating out loud

- The app converts units and counts clicks; keep all copy **descriptive, never prescriptive** ("counter will show…", never "you should take…"). Dose calculators can drift into regulated software-as-a-medical-device territory (TGA/EU) — the informational framing is a real boundary, not just tone.
- AU Privacy Act treats health info as sensitive; E2E design massively reduces exposure but a plain-language privacy policy is still needed at launch.
- No ads, no analytics SDKs that phone home with content; if analytics later, self-hosted + aggregate only.

## Tonight's cut (4 h) **[decided]**

1. Passkeys + PRF + envelope + recovery kit (registration, login, unlock).
2. `pens` blob CRUD + sync; wire the prototype UI (setup / dose / warnings / history list).
3. ICS export.
4. Account panel: delete-everything + passkey list/add.
5. First-run flow: disclaimer acceptance + recovery-kit ceremony (the push-flush action can ship as a stub endpoint).

Deferred: pen registry + recall push (schema is specced above — migrate the table now if cheap, build matching later), reminder escrow, history modal/export/filters, multi-pen carousel, spin-v2 animation.
