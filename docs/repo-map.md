# Repository Map

> Read this before touching anything boundary-sensitive: auth, tenancy, deletion/visibility,
> serialization, background delivery, routing, any external surface. Update it in the same PR as
> any change that moves an edge here. Never leave it describing a stale security boundary — a
> wrong map is worse than no map, because it is trusted.

## What belongs here — and what doesn't

This is a **boundary map, not a directory tree.** Anything an agent can answer with grep/glob in
seconds — where a symbol is defined, which files match a pattern — does *not* belong here: that
content goes stale fastest and helps least. What belongs is the knowledge that lives *between*
files and can't be reconstructed from any one of them:

- **Surfaces** — every distinct way into the system, each with its auth mechanism.
- **Trust boundaries** — for each edge: who is the caller, how is identity established, and what
  happens if they lie.
- **Cross-cutting flows** — the handful of sequences where one action touches many parts, and
  where a change to one part silently breaks an invariant held elsewhere (the classic: soft-
  deleting a record does nothing to a session that looks it up by ID unless every lookup is
  scoped).
- **Risk register** — numbered, stable IDs for known concentrations of risk, so rules, PRs, and
  code comments can cite them.

Start small and grow by incident: three accurate entries beat thirty aspirational ones. When the
map and the code disagree, the code is the truth and the map is the bug — fix it in the same
change that found the disagreement.

## Surfaces

| Surface | Path / entry point | Auth mechanism | Notes |
|---|---|---|---|
| App shell | `GET /` | none (public) | Serves the SPA; all data access happens via the APIs below. |
| WebAuthn registration | `POST /webauthn/registration[/options]` | none for signup; session cookie for add-passkey | Signup mints an anonymous account. Add-passkey additionally requires the client to hold the DEK (it must send a `wrapped_dek`). |
| WebAuthn login/unlock | `POST /webauthn/authentication[/options]`, `DELETE /webauthn/session` | passkey assertion (usernameless, discoverable, UV required) | One assertion both authenticates and (client-side) yields the PRF output that unwraps the DEK. |
| Kit recovery | `POST /recovery/session` | 256-bit recovery proof (HKDF of master key; server stores SHA-256 digest) | The only bare `Account` lookup in the app — auth bootstrap, uniform 401 (no existence leak). No rate limiting yet (R-003). |
| Pens API | `/api/pens*` | session cookie | Blobs in, blobs out; strictly `current_account.pens` (R-001). |
| Credentials / account | `GET /api/credentials`, `DELETE /api/account` | session cookie | Delete = full cascade (credentials, pens) + session reset. |
| Products | `GET /api/products` | none (public reference data) | Presets incl. `counter_style`. |
| Retention sweep | `PenPurgeJob` / `rake pens:purge` | none — background job, no requesting user | Deletes pens past the client-set plaintext `purge_after` TTL. Deliberate owner-scoping exception (R-004). |
| Device flush | `POST /device/flush` | none, deliberately | Walk-away-clean without an account. **Stub** — no push rows exist yet to delete. |

## Trust boundaries

- **Browser ↔ server (the E2E line).** All key material (DEK, PRF outputs, KEKs, recovery master
  key) exists only in client JS memory (`app/javascript/crypto.js`, `auth.js`). The server holds
  ciphertext, wrapped DEKs, and a proof digest. A fully compromised server can deny service and
  serve hostile JS, but the stored data alone decrypts nothing (docs/data-privacy.md threat
  model). Anything that would move plaintext or keys server-side crosses this boundary and needs
  a design change, not a patch.
- **Account ↔ account.** Identity = anonymous account UUID in the session cookie
  (`ApplicationController#current_account`). Every pen read/write goes through
  `current_account.pens`; lying about a pen ID yields 404 (`spec/requests/pens_scoping_spec.rb`).
- **Account ↔ pen registry.** `pen_registrations` has NO account/user column by construction —
  the link lives only inside encrypted pen blobs, client-side. Adding any account linkage (even
  "just for debugging") destroys the recall registry's unlinkability guarantee
  (`spec/models/structural_privacy_spec.rb` pins this).

## Cross-cutting flows

- **Logging a dose:** UI → `history` appended inside the decrypted pen data → whole blob
  re-encrypted client-side → `PUT /api/pens/:id` (owner-scoped) → server overwrites ciphertext
  (last-write-wins; `updated_at` is the tiebreaker). Dose events never exist as rows — a blob per
  pen so row counts can't reconstruct dosing rhythm. A change that "normalises" doses into rows
  breaks this on purpose-chosen property.
- **Losing/regaining access:** passkey assertion (PRF) and recovery kit are two independent wraps
  of the same DEK. Adding a passkey requires an unlocked client (DEK in memory). Server-side
  credential rows can outlive authenticator-side credentials (see AGENTS.md §9.1 — same-
  authenticator re-enrollment replaces).
- **Account deletion:** client should first delete registry rows via IDs held in blobs (none
  exist yet), then `DELETE /api/account` cascades credentials + pens and resets the session.

## Risk register

| ID | Risk | Where it lives | Mitigation / status |
|---|---|---|---|
| R-001 | Dose/click history is sensitive personal health data; a broken owner-scoping check would expose one user's data to another. | `Api::PensController` | Enforced: all queries via `current_account.pens`; cross-account-denied regression test `spec/requests/pens_scoping_spec.rb`. Keep every future pen/dose read path behind the same association. |
| R-002 | Pen-registry unlinkability: any account⇄registration linkage (column, association, join table, log line) rebuilds the account⇄medicine map the design exists to prevent. | `pen_registrations` schema, future registry endpoints | Structural: no account column, uuidv4 PKs, date-quantized `created_on`; pinned by `spec/models/structural_privacy_spec.rb`. Registry create/delete endpoints not built yet — re-check this row when they are. |
| R-003 | `POST /recovery/session` accepts unauthenticated proof attempts with no rate limiting. Proof space is 2^256 so brute force is infeasible, but the endpoint is an online oracle and deserves throttling before public launch. | `RecoveriesController` | Accepted for now; add rack-attack (or similar) before launch. |
| R-004 | `PenPurgeJob` deletes pen rows across all accounts — the one code path that touches pen data without an owner scope (a retention sweep has no requesting user). A bug in its predicate destroys user data irrecoverably, since counta.click holds no key to restore from. | `app/jobs/pen_purge_job.rb` | Selects only on the plaintext `purge_after` TTL (never on ciphertext), boundary-tested in `spec/jobs/pen_purge_job_spec.rb` (TTL today = kept, no TTL = kept). Any widening of that predicate needs the same scrutiny as an auth change. |
