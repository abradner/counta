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
| Web app (Rails) | `/` (all routes, TBD) | Not yet designed | Greenfield — no code exists yet. This is the only planned surface; auth mechanism must be decided before the first user-facing route ships. |

## Trust boundaries

No boundaries exist yet — no code has shipped. The first and most important one to define, before
the first migration lands: **user ↔ their own pen/dose records.** Whatever auth mechanism is
chosen, every lookup of pen/dose/click data must be scoped to the authenticated owner (see
`AGENTS.md` §4.1) — an unscoped lookup by ID is the failure mode to design against from the start.

## Cross-cutting flows

None shipped yet. The first candidate, once auth and dose logging exist: **logging a click/dose**
— request → identify the authenticated user → write the record scoped to that user's pen → the
record must never become visible to any other user's read path. This flow is where a scoping bug
would first surface; add it here in detail once it's actually built.

## Risk register

| ID | Risk | Where it lives | Mitigation / status |
|---|---|---|---|
| R-001 | Dose/click history is sensitive personal health data; a broken owner-scoping check would expose one user's data to another. | Not yet — no model exists. First model to touch this will be the future Pen/DoseLog. | Planned: enforce owner-scoping per `AGENTS.md` §4.1; add a cross-user-access-denied test before the first record-read endpoint ships. |
