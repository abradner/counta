# counta.click — data & privacy design

Status: agreed 2026-08-04 (Alex + Claude design session). Decisions marked **[decided]**; open items marked **[open]**.

## The promise

The operator can **never read your personal information**. Everything identifying or health-revealing is encrypted client-side with a key the server never holds. The server stores the minimum plaintext needed to run the service, and each plaintext field below exists for a stated reason.

## Threat model (what leaks, when)

| Scenario | What an attacker learns |
|---|---|
| DB dump (backup theft, SQLi, misconfigured replica) | Anonymous accounts (no email/name exist), activity timestamps, ciphertext blobs, the pen registry (product+batch ↔ push endpoint, **not** ↔ account), push endpoints |
| Full app-server compromise | Same as above plus live traffic; still no DEKs (PRF outputs never leave the client) |
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
One `pens` row per pen with a single encrypted payload containing: pen details as the user sees them (product, nickname, capacity, total clicks, batch, expiry), full dose log (dose dates — including backdated — clicks, units), dose frequency, per-pen settings, and the pen's registry tokens (see below).

Why a blob, not a row per dose: row counts + timestamps would reconstruct dosing rhythm even with encrypted payloads (doses ≈ capacity ÷ rows). A blob makes logging a dose indistinguishable from any other account activity, dissolves the uuidv7-on-dose-rows question, and last-write-wins sync is fine for a single-user account. A few KB even at hundreds of doses.

### Plaintext, with reasons **[decided]**
| Field | Where | Why plaintext |
|---|---|---|
| Account activity timestamps | `accounts.created_at/updated_at`, uuidv7 PKs | Idle-account sweep; ops hygiene. Accepted leak: "this account touched the server at T". |
| Archived-pen retention TTL | `pens.purge_after` (date, nullable) | Server-side retention sweep (`PenPurgeJob`) for archived pens — a client-side prune can't run for a user who never returns, so the 2-year claim needs a server mechanism. Client-set: archive date + 2 years. Accepted leak: "this pen was archived on ~date T−2y"; nil for in-use pens. Added 2026-08-04. |
| Pen registry: `product_id`, normalized batch, expiry month | `pen_registrations` | Targeted recall push + product usage stats (below). **Not linked to accounts.** |
| Push subscription (endpoint, keys) | attached to registry rows | Recall delivery. |
| Recall list | `recalls` (public) | It's public information. |
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

Client-generated **ICS file** (download/share — not a hosted subscription URL, which would hand the schedule to a server): a recurring dose event for the remaining doses in the pen, plus a "buy more <product>" event ~2 doses before run-out. Deterministic VEVENT UIDs per pen so re-export replaces cleanly. Honest caveat in UI: your calendar provider then holds your schedule — that's the user's tradeoff to make.

## DB hygiene (Rails) **[decided]**

- Keep `created_at`/`updated_at` everywhere. They're the idle sweep, sync conflict tiebreaker, and debugging backbone; with blob-per-pen they no longer proxy dose events.
- uuidv7 PKs for `accounts`, `pens`, `webauthn_credentials` (index locality; embedded creation time is accepted activity metadata). uuidv4 **only** for `pen_registrations` (severs timing linkage).
- **No pgcrypto / server-side column encryption** (incl. Rails `encrypts`): keys would have to exist server-side at query time, which breaks "the operator can never read it" structurally. The client-side envelope already covers the stolen-disk/backup threat pgcrypto addresses; deliberate plaintext (registry, timestamps) must stay plaintext to do its job. Decided 2026-08-04.
- Indices only on what's queried: `pens.account_id`, `pen_registrations (product_id, batch)`, `accounts.updated_at` (idle sweep), `webauthn_credentials.external_id`.
- Ciphertext is opaque — nothing else needs indexing.

## Policies

- **Archived pens**: a finished/expired pen can be archived rather than trashed — it keeps its dose history and batch number and drops out of the dose UI. Retention is 2 years from archiving, enforced server-side by `PenPurgeJob` against `pens.purge_after` (trashing is still immediate and total). **[decided 2026-08-04]**
- **Idle deletion**: accounts untouched for 2 years are deleted (defined by `accounts.updated_at`). With no plaintext contact channel there is no pre-deletion warning email — a push warning at ~23 months is possible where a subscription exists. Document the policy publicly. **[decided]**
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
