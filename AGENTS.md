# Counta — Agent Onboarding Guide

> Read this file first. It is the source of truth for AI agents working in this codebase.
> Plans, status, and decision rationale live in GitHub Issues, not in a repo file. When this file
> and an issue disagree on architecture or direction, the issue wins — update this file to match,
> never the reverse.
> This file is operational: how to build, run, and write code here.

## 1. What Is This?

Counta is a simple, secure, easy-to-use tool for counting clicks on measured-dose pens (e.g. Novo
Nordisk's FlexTouch) — the kind of pen injector where a dose is dialed by turning it a number of
"clicks," each an audible/tactile detent. Counta helps a user track those clicks/doses over time
without the manual tally-keeping that's easy to lose or get wrong. Status: first working cut
(2026-08-04) — passkey+PRF envelope crypto, encrypted pen blob CRUD, dose UI ported from the
prototype, ICS export, account panel, first-run flow. Design authority: `docs/data-privacy.md`
and `docs/design-notes.md` (don't re-litigate items marked [decided]).

Domain nouns an agent will encounter:
- **Pen** — a physical measured-dose injector device belonging to one user.
- **Click** — one detent/turn of the pen's dial; the physical unit the user counts, not
  necessarily the same as a medication dose unit (some pens' click-to-dose-unit ratio isn't 1:1 —
  don't assume it is without checking the specific pen model).
- **Dose** / **dose log** — a recorded event of clicks dialed and/or administered, tied to a pen
  and, transitively, to exactly one owning user.

## 2. Purpose & Principles

**Purpose:** Make counting pen clicks/doses trivially easy and safe for the person doing it, without
ever putting that person's health data at risk — every design decision should serve ease of use,
accessibility, or the privacy/security of the individual owner's data, in that order when two
pull apart.

Principles: short, numbered, memorizable. Each one must be able to change a real decision — a
principle that never changes a decision is decoration.

1. **Claims must hold.** A doc, comment, or commit message claiming a property the mechanism
   doesn't deliver is a bug, not documentation. Interim states say so in-place ("stated, not
   enforced — landing in E7"); stopgaps record the bar they miss. *(Portable seed — keep, adapt,
   or replace. It has caught real security bugs, twice, in a sibling repo, by being invoked
   against the project's own earlier claims.)*
2. **Privacy is structural, not promised.** A user's dose/pen data must be inaccessible to anyone
   but that user by construction — scoped at the query/authorization layer, not merely covered by
   a privacy-policy sentence. A privacy claim the data model doesn't enforce is exactly the kind of
   claim principle 1 forbids.
3. **Accessible by default.** Every user-facing surface must be usable via screen reader and
   keyboard alone, and legible at large accessibility text sizes — checked before merge, not
   retrofitted after a complaint.
4. **Trivially easy to use.** If logging a click/dose needs more than a couple of taps, or needs a
   tutorial to use once, redesign it — the tool only earns its place if it's faster and more
   reliable than a manual paper tally.
5. **Secure by design.** Prefer mechanisms that make an insecure state unrepresentable
   (parameterized queries, scoped associations, encryption for sensitive fields) over defensive
   checks bolted on afterward.

### The tripwire protocol

A conflict with a principle is a stop-and-check, never something to quietly work around:

- If **your own approach** conflicts with a principle, treat that as a strong signal the approach
  is wrong. Re-derive it before proceeding — the principle has usually seen more failures than
  this session has.
- If the **operator's request** conflicts, say so explicitly, naming the principle. Then exactly
  one of two things is true:
  - **The principles have evolved.** Update the principle in the same change — and demand the
    justification: the *why* gets recorded next to the amendment, because an unjustified
    amendment is indistinguishable from erosion.
  - **The principles stand.** Then the request should be reconsidered — propose the nearest
    conforming alternative and let the operator choose with the conflict in view.
- Never proceed silently with a violation. An unremarked exception teaches every future reader —
  human or agent — that the principles are decorative (see §10, meta-rule 1).

## 3. Stack at a Glance

| Layer | Technology | Notes |
|---|---|---|
| Language | Ruby | managed via `mise` — see `mise.toml` |
| Framework | Rails | |
| Database | PostgreSQL | |
| Testing | RSpec | |
| Deployment | Athena (Talos k8s, Argo CD gitops) | image from `ghcr.io`, built by `Dockerfile` + `.github/workflows/docker.yml`; cluster manifests live in `athena-gitops` — see §7 (this row read "undecided" until #52) |

## 4. Critical Architectural Rules

These are non-negotiable. Violating them will break things or be rejected in review.

### 4.1 Every data access scoped to its owning user

All reads/writes of pen, dose, or click data must be scoped through the current account's own
association (`current_account.pens.find(id)`), never a bare unscoped lookup by ID
(`Pen.find(id)`). An unscoped lookup is exactly how one user's dose history becomes visible to
another. Enforced since the first cut: `Api::PensController` scopes every action, and
`spec/requests/pens_scoping_spec.rb` is the R-001 cross-account-denied regression test. The one
deliberate bare lookups are the two auth-bootstrap ones, where there is no user to scope by yet:
`ApplicationController#current_account` (resolves the session cookie) and `RecoveriesController`
(gated on the 256-bit recovery proof — see the comment there). Everything else scopes.

### 4.2 Dose/click data is sensitive and opaque by default

Treat pen/dose/click records as sensitive personal health data: never log them in plaintext
(Rails parameter filtering covers blob/batch/expiry/dek/credential fields —
`config/initializers/filter_parameter_logging.rb`, pinned by
`spec/models/structural_privacy_spec.rb`). Encryption at rest goes further than the original
"Rails `encrypts`" wording: every dosing-history field lives inside the client-side AES-256-GCM
pen blob and the server never holds the keys (`docs/data-privacy.md` "Crypto design" — that doc
supersedes the earlier server-side-encryption phrasing; server-side `encrypts`/pgcrypto would put
keys where the design promises they never go). Plaintext columns are limited to the data map's
enumerated list.

## 5. Docs Map

Four docs, each with a distinct job. Keep them that way — a doc that drifts into
another's territory is how two of them end up disagreeing:

| Doc | Job |
|---|---|
| `docs/data-privacy.md` | **Authority** for the data and crypto design: the data map, threat model, retention policy. Items marked `[decided]` are settled; amend in place with a reason rather than re-litigating. |
| `docs/design-notes.md` | **Authority** for UI/UX decisions: dose entry, counter-style copy, the pen graphic. Also holds the standing **anti-roadmap** — the features counta deliberately won't grow. |
| `docs/architecture.md` | *Why the code implements those decisions the way it does* — the reversal-expensive choices and the code that looks odd without its constraint. Explains, never decides. |
| `docs/repo-map.md` | Surfaces, trust boundaries, cross-cutting flows, risk register. |
| `docs/ui-tour.md` | Screen-by-screen walkthrough with generated screenshots. |

`docs/repo-map.md` is the living boundary map: surfaces, trust boundaries, cross-cutting flows,
and the risk register. It exists because that knowledge lives *between* files and can't be
reconstructed by grep — and because cold-started subagents and future sessions get no
conversation context, only what's written down.

- **Read it before touching anything boundary-sensitive**: auth, tenancy, deletion/visibility,
  serialization, background delivery, routing, any external surface.
- **Update it in the same PR** as any change that moves an edge on it. Never leave it describing
  a stale security boundary — a wrong map is worse than no map, because it is trusted.
- Cite risk-register IDs (R-00N) from rules, PRs, and code comments, so the register stays
  load-bearing instead of decorative.

## 6. Development Essentials

All commands run with `mise exec --` (or after `mise install` + shell activation) so a fresh
shell resolves the pinned Ruby, not whatever's on `PATH`. PostgreSQL comes from docker-compose.

```sh
docker compose up -d db                      # Postgres 18 on host port 25432
mise install
mise exec -- bundle install
mise exec -- bundle exec rails db:prepare db:seed
mise exec -- bundle exec rails server -d -b 0.0.0.0 -p 25425   # dev server
mise exec -- bundle exec rspec               # full suite (system specs need chromium)
```

Pre-deploy testing: `https://counta.click` maps to this host's port 25425 (TLS terminated
upstream at haproxy; the server must listen on `0.0.0.0`). **Use that hostname, not
`localhost:25425`** — WebAuthn binds ceremonies to an exact origin, and development is configured
for `https://counta.click` only (the test env is the one that uses localhost). See
`config.x.webauthn_*` in the environment files.

That also means development is exposed to the internet, which it isn't built for: `web-console`
is explicitly denied in `config/environments/development.rb` for that reason (R-005). A real
deployment should run `RAILS_ENV=production`.

### 6.1 Known Environment Gotchas

Things that cost real time to discover once — don't rediscover them. Add entries as they're found;
add rather than rewrite.

(Entry shape: the symptom, the actual cause, the workaround. Host quirks, port collisions with
sibling projects, toolchain path issues, platform limitations.)

1. **haproxy 503 right after server start** → haproxy's health check hasn't seen the backend yet
   → wait ~5–10 s and retry; not an app failure.
2. **`rails server -b 0.0.0.0` serves port 3000, haproxy 503s forever** → `-b` replaces the whole
   puma binding, discarding the port configured in `config/puma.rb` → always pass `-p 25425`
   together with `-b`.
3. **No chromedriver exists for linux-arm64** (this dev box is a Raspberry Pi) → system specs use
   Cuprite/Ferrum, which drives Chromium over raw CDP — which is also how the WebAuthn virtual
   authenticator (PRF) is injected. Don't add selenium-webdriver.
4. **`bundle exec rspec | tail` hides failures** — a pipeline's exit status is the last command's,
   so `rspec | grep … && git commit` will happily commit over a red suite. Bitten twice in one
   session. Read the "N examples, M failures" count; don't rely on `&&`.
5. **Headless Chromium can't keystroke `<input type=month>`** (locale-formatted typing) → set the
   value via JS and dispatch a `change` event; see `save_pen` in `spec/support/counta_flows.rb`.

## 7. CI & Deployment

CI: `.github/workflows/ci.yml` runs `bundle exec rspec` (including the browser system specs) on
every PR and push to main, with the mise-pinned Ruby and a Postgres 18 service on the same port
as local dev. A separate `lint` job runs Rubocop (`.rubocop.yml`), Brakeman, and bundler-audit —
run `mise exec -- bundle exec rubocop` locally before pushing. (This sentence used to say "no
linter is adopted yet"; that was stale from before #1 landed the lint job — corrected 2026-08-09
per §10 meta-rule 1.)

**Deployment target is decided.** This section used to say "Deployment is undecided — don't build
for it until asked", meaning don't write Dockerfiles, manifests, or release plumbing on spec.
Issues #6/#10 were the asking; #52 (`5c0b8b5`) landed the image and pipeline and #51 the app-side
config. Corrected in place per §10 meta-rule 1.

The target is the **Athena** cluster — Talos Kubernetes, Argo CD gitops, workers are Raspberry Pi
arm64. The gitops manifests (Deployment, Service, Ingress, the retention-sweep CronJob for
`rake pens:purge`, External Secrets pulling `DATABASE_URL`/`RAILS_MASTER_KEY` from 1Password) live
in the separate `athena-gitops` repo, **not here** — this repo's responsibility ends at publishing
a runnable image. What survives of the old rule is exactly that boundary: image and build-time
concerns are in scope here; rollout and cluster concerns are not — for those, ask.

Cutover has not happened. `counta.click` still maps to the §6 dev server; flipping DNS/HAProxy to
the cluster is a separate tracked step (`docs/repo-map.md` R-005, issue #10). **Don't treat "the
image builds" as "cutover happened."**

What the publish pipeline actually does (`.github/workflows/docker.yml`, image
`ghcr.io/abradner/counta` — the workflow writes `ghcr.io/${{ github.repository }}`, which expands
to the full `owner/repo`, not a bare repo name):

- **Push to `main`** → build and push `:sha-<full-sha>`, then alias `:latest` onto that digest —
  but only if `main`'s remote tip is *still* the commit that was built. That guard exists because
  a rerun of an old completed run would otherwise drag `:latest` backwards, which `concurrency:`
  alone can't catch.
- **Push a `v*` tag** → build and push `:<tag>`. `flavor: latest=false` is deliberate: a tag build
  never moves `:latest`. No `v*` tag has been pushed yet.
- **Pull request** → builds `linux/arm64` natively and pushes **nothing**. A pre-merge smoke test
  that the image still builds.
- **`workflow_dispatch`** → manual build on any branch (e.g. to test-deploy one). The `latest`
  step is skipped for any ref that isn't `main`.
- **Branch pushes** → nothing. Only `ci.yml` runs.

Every build is `linux/arm64` only — the cluster's architecture. The former QEMU-built amd64
convenience target was dropped for build speed; x86 hosts can `docker build` locally, and the
workflow comment records the native-runner path if publishing amd64 ever returns.

Two universal cautions, whatever the pipeline:

- **A skipped job is not a passing job.** A green run where path filtering skipped half the suite
  means that half never saw the commit. Check what actually ran before trusting the check. This
  repo had a live instance of exactly that, written up here between #54 and #51: `docker.yml`
  didn't run on PRs, so a change to `Dockerfile`, `.dockerignore`, or `bin/docker-entrypoint` got
  a green PR from `ci.yml` having never been built, and first broke on the post-merge `main` run
  — the same run that moves `:latest`. #51 closed it structurally by adding the `pull_request`
  trigger (§10 meta-rule 5: make it mechanically true rather than warning about it in prose).
  Kept here as the worked example, not as an outstanding gap.
- **A test job that cannot distinguish "everything passed" from "nothing ran" is not a gate.**
  When a test runner is swapped, changing the local command is half the job: read what CI actually
  invokes and confirm the run count it reports is non-zero. (A generated workflow in a sibling
  repo kept running the abandoned runner against an empty directory — green on every push while
  executing zero examples, because "no tests found" was a success to it.) Applies equally to any
  generated pipeline adopted wholesale.
- **A gate fails only for reasons inside the diff.** Dependency currency belongs to scheduled
  tooling (dependabot, audit jobs), not to a PR gate — nothing should be able to redden a PR that
  changed no dependencies, on a schedule set by someone else's release cadence. A gate that cries
  wolf gets ignored, including on the day it is right. (Instance: a generated scanner wrapper
  passed `--ensure-latest`, so an upstream release turned every PR in a sibling repo red while
  reporting a version fact through the channel reserved for security failures.)
- **A merge is not a release** — this used to read "if images/artifacts build from tags only,
  merged work has no deployable artifact until a tag exists. Not yet applicable — no
  release/artifact flow exists." Now applicable, and this repo is the *opposite* shape, so the
  caution inverts rather than disappears: (a) every merge to `main` publishes an image and
  repoints `:latest`, so for anything consuming `latest` **merging is the release** — there is no
  later "and now ship it" step in which to catch a mistake; and (b) a `v*` tag deliberately does
  not move `:latest`, so a tagged release is not what `latest` consumers are running.
  Concretely, and this is the part that makes (a) bite: the `athena-gitops` manifests track
  `:latest` with `imagePullPolicy: Always`, so a merge here publishes `:latest` and the next pod
  restart on the cluster picks it up with no separate release step. That is a known gap on the
  gitops side — a documented upstream TODO is to pin to `sha-` tags instead — not a property this
  repo is claiming is good. Until `athena-gitops` moves off `:latest`, a merge to `main` here is
  closer to a release than the general rule implies.

## 8. Working Rules

The portable core. These rules are pre-filled from hard-won convention across this repo's sibling
projects; adjust only with reason, and record the reason (see §10).

### Planning & approval

- Propose an implementation plan for any moderately or highly complex change, and get it reviewed
  and approved before making edits. Don't dive into large builds or refactors on your own read of
  the situation.
- For anything genuinely ambiguous or not yet decided by the operator, prefer the reversible
  option and leave a clear marker rather than picking silently. Two-way doors over one-way doors.

### Landing changes

- **Every change lands through a pull request** — including one-line copy tweaks. Size is not the
  criterion. The cost is a minute; the cost of the habit eroding is that "it was only docs" becomes
  the reason something real lands unreviewed. (Motivating instance: a few commits went straight to
  `main` during a sibling repo's init. Automated reviewers fire on the ready-for-review edge, so a
  direct push is a change nothing reviewed, and `main`'s history stops meaning "reviewed states".)
- Opening a PR is not merging it. Push permission is granted per session — ask once before the
  first push unless already told.

### Destructive & outward-facing actions

- Destructive actions (dropping data, deleting files you didn't just create, rewriting published
  history) and outward-facing actions (publishing, sending, deploying) need explicit approval,
  every time. Approval for one instance is not approval for the next.
- **Never force-push to `main`. There is no go-ahead for this — not from a green build, not from
  the operator, not to tidy history.** Every other destructive git operation is "ask first"; this
  one is simply off the table. (Operator instruction, 2026-08-05, after an agent — me — pushed a
  docs commit straight to main unasked. That single instance was let stand only because that
  session would finish before anything shipped. It is **not** a standing exemption for
  pre-production: committing to `main` still needs a go-ahead, whatever the environment. Branch
  protection lands before production, at which point the tooling enforces what this paragraph
  asks for.)
- Never merge to a shared branch, or rewrite published history, without an explicit, current
  go-ahead. A green build and an auto-mode session default are not that signal — if the work is
  ready, say so and stop.
  Every new session starts assuming that manual gate. Two carve-outs are real, and only these:
  - A **conditional, forward-looking** go-ahead is still a go-ahead: "merge this train once #38 is
    resolved" names the batch and states the condition, and covers merging while the operator is
    away. It authorizes *that* batch only.
  - A **session-scoped carve-out** ("auto-merge only trivial mechanical PRs tonight") is valid when
    the operator sets it — at session start, as their own policy choice. Treat it as a one-session
    precedent and ask again next time; anything touching auth, scopes, custody, or an API contract
    stacks and waits regardless.

  Ambiguous continuations ("continue the stack flow") are **not** authorization — ask briefly,
  citing this rule so it doesn't read as timidity. And **do not propose loosening this.** The
  operator's position is that they would like to soften it eventually but that harnesses are not
  reliable enough yet.
- **Visibility and content are separate axes.** Before making anything public, do not let a narrow
  confirmation (repo name, a visibility toggle) stand in for consent to the *content* — git
  history, comments, and design docs go out too. Separately flag anything describing a
  still-unfixed vulnerability or written more candidly than the operator likely pictured, and ask
  about that specifically. (A sibling repo was pushed public with candid commit messages
  documenting exact vulnerabilities, one of them still live in the code at push time; it had to be
  flipped back to private immediately.)
- If you encounter a violation of a safety rule already committed (a plaintext secret, a
  destructive migration lying in wait), flag it immediately — finding it is not the same as
  having caused it, and silence helps nobody.

### Tooling version floors

- **A version floor is an interrupt, not a workaround.** When a skill or workflow depends on
  tooling at or above some version and the environment is below it, stop and tell the operator
  what to upgrade. Do not silently take a degraded path, reimplement the missing capability by
  hand, or work around it — the operator can fix an install in seconds, and the workaround is
  what ends up load-bearing and unreviewed.
- Distinguish **fixable** from **unavailable**. A missing or outdated tool is fixable: interrupt.
  A capability the platform genuinely doesn't offer here — wrong host, feature not enabled for
  this repo, a documented limit — is unavailable: take the documented fallback and record why.
- Name the floor and the exact upgrade command when you interrupt. "Your `gh` is too old" costs
  the operator a search; "`gh extension upgrade stack` — `merge` landed in v0.1.0" does not.
- The same applies mid-run: if tooling turns out to be below the floor after work has started,
  stop and say so rather than finishing on the degraded path and reporting success.
- **Adding a dependency can raise the project's floor without asking.** Package managers resolve a
  new dep's own requirements by bumping yours. After any dependency add, read the manifest diff for
  the language/toolchain lines specifically; if a dep forced a bump, pin the *dep* to the newest
  version whose floor matches the repo rather than raising the repo. A toolchain bump touches the
  production image and is a deliberate decision, not a side effect of installing something.
  (Instance: `go get <dep>@latest` rewrote `go.mod`'s Go version and deleted the `toolchain` pin,
  breaking the Docker build against a pinned base image. The `test` job still passed — only `build`
  caught it.)

### Configuration

- Fail fast on boot: never provide fallback defaults when reading *required* configuration.
  Missing required config must raise at startup rather than silently degrade. Defaults are fine
  for genuinely optional tuning knobs. (This isn't hypothetical: a sibling repo baked a stand-in
  value into an image-wide ENV to make a build step pass, which would have silently defeated this
  rule in production. If a build step needs a stand-in, scope it to that step, never image-wide.)
- The same explicitness applies to what the code writes: anything persisted that holds data states
  its permissions explicitly rather than inheriting the process umask. (Database dumps in a
  sibling repo landed world-readable because the dump path never asserted a mode.)

### Review feedback

- **A finding is a claim, not a verdict.** Whether it comes from a bot, a human, or your own
  earlier session: trace or reproduce it before acting on it. Ask whether the flagged path is
  actually reachable. When a finding says code and docs disagree, work out which end is wrong
  before "fixing" either. Declining findings has to actually happen — a round that accepts every
  finding is a warning sign, not a good score.
- **Verify a delegated claim against the artifact before relaying or acting on it.** Read the
  diff, grep the branch, run the command — a subagent's report is a claim like any other. (Two
  agents once filed contradictory security reports and *both were correct about different
  artifacts*; only diffing them resolved it, and doing so exposed a real defect — a branch that
  deleted a control introduced by the PR below it, which the final merge accidentally restored.
  Separately, an agent has returned a placeholder summary while having done complete, correct work:
  believing the report would have discarded it.)
- Reject suggestions that violate the rules in this file, and say why. Automated reviewers read
  this file too; that's expected — reviewer-side agents should review fully as normal, and rules
  here that bind only author-side agents say so explicitly.
- **Bot roster:** Copilot auto-reviews every PR (cheap, unrationed). Codex/Claude review by
  request — expected to actually be requested on any non-trivial PR that won't otherwise get
  substantial human review before merge.

### Testing & verification

- **Verify the output, not the instrument.** Green means nothing threw, and nothing more. Before
  claiming something works, name the artifact it should have produced and go look at it — the
  rendered page, the written file, the actual rows. A tool reporting on itself is not the
  artifact: `git bundle verify` once passed on backup bundles that could not actually be cloned,
  because the verifier checks internal structure, not that the bundle can reconstitute a repo —
  the suite that replaced it performs a real clone.
- **Prove a new test can fail.** For any bug fix: write the regression test, confirm it passes
  with the fix, revert just the fix, confirm the test fails for the right reason, restore the fix.
  A test that was never seen to fail hasn't proven anything. This is part of writing the fix, not
  review debt to defer — one reviewer's "add regression coverage for your own fix" finding recurred
  three times across a single PR series and was right every time. And the mutated code must
  *compile*: a build-failed mutant proves nothing.
  - This is the single highest-yield habit in this repo — it has caught a hollow test *five*
    times, and every time the test looked convincing first. Budget for it; it costs a minute.
  - **A revert that doesn't fail doesn't mean the test is good — diagnose which of these it is:**
    1. **Two independent guards.** Reverting one leaves the other covering it, so the spec still
       passes. Revert *all* of them, or the proof is vacuous (§9.10).
    2. **The spec never reaches the mechanism.** Ordering or setup means the code under test
       doesn't run at all — a stale-tab merge spec that reloads first is never stale; a retention
       spec that opens a pen never saves it (§9.8, §9.10).
    3. **The lever is a no-op.** The thing you changed to reproduce the failure doesn't affect
       the output — Chromium's `--lang` versus `Intl` (§9.9). Confirm the lever moves the output
       *before* concluding anything from it.
    4. **False positives are masking real ones.** A check that flags noise gets tuned until it's
       quiet, and the tuning hides the signal. Look at what a guard *stops* flagging.
    5. **A sequential test can't see a concurrent defect.** Races need real threads on separate
       connections; a single-threaded spec passes regardless (`spec/models/pen_concurrent_write_spec.rb`).
- **For any isolation or authorization test, name the attacker and write *their* request.** A spec
  that asserts the mechanism's own definition back at itself cannot fail for any input — it reads
  like coverage and gates nothing. If you cannot describe an input that would make the assertion
  fail, the test is documentation, not a gate.
- **Inference from a plausible nearby cause is not diagnosis.** During a platform outage, a red
  main was attributed to the outage's known error; the outage was real but unrelated, and the
  actual job failure had been there all along. Wait for the real signal and read the actual
  failure before naming a cause.
- **Watch the setup, not just the assertion.** Four tests in one feature passed against genuinely
  broken code because their setup could never exercise the branch — an assertion on node count
  only, a fixed `now` so the fade never completed either way, a payload rejected as malformed
  before its size mattered. Also beware a test that captures current behavior so faithfully it
  archives the defect.
- Ask what else satisfies your assertion — a count-based check that an empty-state row also
  matches, a visibility check that passes for a scrolled-away element. When asserting absence,
  include a positive control so a broken probe can't read as success.
- Every conditional branch that encodes real logic gets a test that exercises it — especially the
  rare/edge branches, not just the happy path.

### Git hygiene in shared checkouts

- **Create branches only from an explicit start point** (`git checkout -B <name> origin/main`) when
  anything else might be operating in the same checkout, and check `git branch --show-current`
  before any operation that depends on HEAD. (A "one-line docs PR" silently inherited five feature
  commits from an in-repo builder agent's branch and was reviewed in that state. "Only one builder
  running" is not "only one git user"; prefer worktree isolation for delegated builders.)
- **Never pair `git stash` with a later `pop` unless the stash verifiably created an entry.** A
  stash on a clean tree stashes nothing, and the paired pop then pops whatever stranger's entry was
  on top of a stack you don't control. For "test against a clean copy", use `git show REV:path` or
  a scratch worktree instead of stashing at all.

### Layered checks

- Apply the **deletion test** to any validation that exists in more than one place: enforcement
  exists exactly once; anything layered on top must, if deleted, change only politeness (a
  friendly error instead of an ugly one), never possibility. If deleting either check would make a
  new state possible, you have enforcement in two shapes, and they will drift.

### Documentation & discovered work

- Docs describing a boundary or behavior change in the same PR as the change. A doc describing a
  boundary that no longer exists is worse than none, because it is trusted.
- Log discovered work (bugs found in passing, deferred improvements) in the external tracker —
  never a PR body or a code comment. A triage table in a PR body goes stale between rounds and
  vanishes on merge.
- When you fix a subtle bug or get burned by a non-obvious behavior, write the general form of the
  lesson into §9 before moving on — same session, not later.

### Tooling

- Use the agent's structured file tools rather than `cat`/`sed`/shell here-docs for inspecting
  and modifying files during a session. (Scope: this governs session file operations; committed
  shell scripts do what shell scripts do.)

### Which shipping flow

- The default is one PR at a time: react to feedback immediately, merge when green. Use
  `.claude/skills/single-pr` — it makes that default rigorous rather than merely simple.
- Several PRs open together as one body of work is a different regime: use
  `.claude/skills/batch-review` (fan out, feedback write-only until synthesis, one followup PR).
  It is opt-in for genuine multi-PR fan-outs, not a replacement for the default. The tell is
  reviewer attention fragmenting across live threads, not the size of the diff.
- Both skills read `docs/pr-review-machinery.md` for the parts that don't differ between them —
  reviewer triggers, the three-surface comment harvest, triage, the round cap, and the green-signal
  traps. It is the canonical copy; don't restate it in a skill, and don't let a skill contradict it.
- When more than one branch is in flight against the same code — or any branch went through an
  agent-performed merge or rebase — run `.claude/skills/stack-integration-check` before opening
  PRs. Per-branch review is structurally blind to what happens between branches; this is the check
  that runs on the combination.

### Context & compaction

- When the operator signals they are near the context limit and about to compact, use
  `.claude/skills/park-context` rather than improvising a summary. Compaction keeps a paraphrase
  and discards the transcript, so the park writes only what compaction destroys — intent, rejected
  alternatives, what was actually verified versus assumed, what was mid-flight when the turn was
  cut — and never the diff, which is reconstructible.
- Do not finish work, commit, or push while parking. Parking is triggered by interrupting a live
  turn, so the tree may hold a partial edit nobody intended; record it as observed and stop.
- Resuming from a handoff uses `.claude/skills/resume-context`. The handoff is a claim, not a
  verdict (see Review feedback above) — the session that wrote it is gone and cannot be asked what
  it meant. Verify its state claims against the repo and report drift before building on them.
- Durable lessons never live in a handoff. They land in §9 / §6.1, or in the external tracker,
  before the work merges — handoff files are gitignored local state and get deleted.

## 9. Gotchas & Lessons Learned

Numbered, accreting. Add to it rather than rewriting it — the numbering is stable so entries can
be cited from code comments and PR descriptions.

Entry shape: **what happened → the actual root cause → the general rule → where the regression
test lives** (if one exists).

1. The envelope spec tried to delete the first passkey from the virtual authenticator after
   enrolling a second one and got "credential not found" → discoverable (resident) credentials
   are keyed by (rpId, userHandle), so enrolling a second passkey for the same account on the
   SAME authenticator silently *replaces* the first → never assume server-side credential rows
   and authenticator-side credentials stay 1:1; design add-passkey flows and their tests around
   replacement → `spec/system/crypto_envelope_spec.rb` (asserts the replacement, then proves the
   second credential's unwrap path).
2. `ENV.fetch` for production-only required config placed in `config/database.yml` ERB crashed
   dev/test boot → the ERB in database.yml is evaluated in every environment when the file is
   parsed → scope required-config fail-fast to the environment that requires it
   (`if Rails.env.production?`), which keeps the fail-fast without breaking other envs → boot of
   any env exercises it.
3. "Hidden" app sections (pen graphic, empty error pills) rendered on the landing page → the
   `hidden` attribute only works via the UA stylesheet's `display:none`, which ANY authored
   display rule on the same element (`main{display:grid}`, `.warn{display:flex}`) silently
   overrides → every stylesheet that toggles visibility with `hidden` needs
   `[hidden]{display:none !important}` → `spec/system/landing_spec.rb`.
4. Signup failed for a real 1Password-on-iOS passkey that the virtual-authenticator suite passed
   → two provider quirks: `prf.enabled` in the create() result is unreliable (only an assertion
   that yields no PRF output proves "unsupported"), and the follow-up get() can throw
   NotAllowedError because create() consumed the user-activation gesture → treat create-time PRF
   signals as a fast path only, and design any WebAuthn-call-after-WebAuthn-call flow to re-ask
   for a user gesture (`requestGesture`, defined in `app/javascript/app.js` and passed into
   `passkeys.js`) → the virtual
   authenticator can't reproduce this; covered by the manual walkthrough's signup step.
5. Saving a pen 422'd on a real device (and delete-account failed silently) while the whole
   system suite was green → two causes stacked: `reset_session` in signup/login/recovery rotates
   the CSRF token so the open page's `<meta>` token goes stale, AND Rails disables forgery
   protection in the test env so no spec could see it → any endpoint that resets the session must
   hand the client a fresh CSRF token in its response (`fresh_csrf` /
   `adoptCsrfToken`), and browser-driven system specs must run with
   `ActionController::Base.allow_forgery_protection = true` → `spec/support/system.rb` (around
   hook) makes every session-rotating system spec a regression test.
6. An archived pen's 2-year retention deadline landed a day early → the browser calculated it and
   `toISOString()` converted local midnight to the previous day in UTC+10 → **don't calculate
   dates or deadlines in the browser at all.** The server owns them (ActiveSupport,
   `Pen::ARCHIVE_RETENTION`), everything crosses the wire as UTC ISO8601, and the client only
   formats for the local zone. Where a local *calendar* date is genuinely the right thing (a
   user-entered dose date), build it from local getters, never `toISOString()` →
   `spec/requests/pens_archive_spec.rb`.
7. The prototype's small-screen shortcut (`.app{zoom:0.82}`) shipped into the real app and broke
   iOS layout → `zoom` doesn't scale native form controls, so date/month inputs kept their
   intrinsic width and overflowed their card → do the real responsive pass (breakpoint sizing +
   `appearance:none` on date inputs) rather than porting a prototype-only hack; treat
   "prototype only" notes in design docs as load-bearing.
8. A spec claiming "re-saving an archived pen doesn't restart its retention clock" passed with
   the guard deliberately removed → it drove the UI through a path that never issues a save, so
   it asserted an unchanged value that nothing had tried to change → when a test targets an
   invariant, revert the mechanism and watch it fail *before* trusting it; if the invariant isn't
   reachable from the UI, test it at the layer where it is (request spec, not system spec) →
   `spec/requests/pens_archive_spec.rb`.
9. A system spec asserting `"Archived 9 Mar 2025"` passed locally and failed on CI, which renders
   `"Mar 9, 2025"` → the app formats server-sent UTC instants in the *viewer's* locale (correct
   for users), and the browser takes that locale from the environment → **don't assert on
   locale-formatted text**; render `<time datetime="…">` and assert the machine-readable
   attribute. Reproduce a locale-dependent failure locally with `LC_ALL=en_US.UTF-8` — that does
   drive Intl, whereas Chromium's `--lang` flag does **not**. The first attempted fix pinned
   `--lang` and "passed", which proved nothing: when fixing an environment-dependent test, first
   confirm the lever you're pulling actually changes the output (`spec/support/system.rb`,
   `spec/system/multi_pen_and_archive_spec.rb`).

10. Three regression specs in one session passed with their fix deliberately removed, each for a
    different reason: the custom-pen dose bug had **two independent guards** (storage and clamp),
    so reverting either alone left the other covering it; the stale-tab merge spec **reloaded the
    page before the conflicting write**, leaving the tab current so the merge never ran at all;
    and the copy guard's **false positives had been tuned away** in a manner that also silenced
    the real ones → the general rule: when a revert doesn't produce a failure, that is a finding
    about the *test*, not a licence to move on. Work out which shape it is (§8 lists them) before
    trusting the spec → `spec/system/pen_flow_spec.rb`, `spec/system/sync_conflict_spec.rb`,
    `spec/i18n_spec.rb`.

## 10. Maintaining This Document

Meta-rules for editing this file — they exist because each was violated somewhere first:

1. **A rule everyone knows is wrong is worse than no rule** — it teaches agents that the rules are
   decorative, which devalues the ones that are load-bearing. When reality has moved, revise the
   rule openly: state what the old rule said, why it was the wrong shape, and what replaces it.
2. **Ground rules in incidents.** When adding a rule, say what happened. When correcting a wrong
   rule, record the correction in-place so the old rule doesn't get quietly reintroduced.
3. **Scope absolutes.** Name the exceptions at authoring time, or agents will either violate the
   rule or over-apply it.
4. **Name the audience** when a rule doesn't bind every reader — author-side agents, reviewer
   bots, and humans all read this same file.
5. **Prefer structural guarantees to written claims.** If a rule can be made mechanically true (a
   build-context exclusion, a CI gate, an import stub instead of a second copy), do that and
   document the mechanism, rather than adding another sentence.
6. **Expect to compress.** First-draft steering prose runs vague and grandiose; cut it to concrete
   nouns and commands the same day. When compressing an established doc, treat it like a refactor:
   diff the imperatives before/after and confirm nothing operative was dropped.
7. **Porting rules between sibling repos is judgment, not copying.** Verify each candidate rule
   against this repo's own files, CI, and conventions; adopt, adapt, or reject explicitly — and
   note rejections in the Adaptation Record below. Watch especially for rules that silently assume
   another repo's merge strategy, bot roster, or deploy shape.

## 11. Adaptation Record

What was pruned or changed from the keel template when this repo was initialized, and why — kept
in the doc (not just a commit message) so future readers don't need git archaeology to know what
was deliberately excluded.

Initialized 2026-08-03, from an operator interview (see PR/commit that introduced this section):

- **Project**: Counta — a click/dose counter for measured-dose pens (e.g. FlexTouch). Greenfield;
  no application code yet.
- **Principles**: captured, not deferred — privacy-as-structure, accessibility-by-default,
  trivial ease of use, and secure-by-design, ranked in that priority order when they conflict (§2).
- **Stack**: Ruby on Rails + PostgreSQL + RSpec, chosen up front. Deployment target left undecided
  on purpose — §7 says so explicitly rather than guessing at a platform.
- **Tracker**: GitHub Issues, not Notion/Linear — the tracker-pointer language in the header and
  §8 "Documentation & discovered work" was written against GitHub Issues accordingly.
- **License**: kept Apache-2.0 (public repo; operator confirmed no swap needed).
- **Merge strategy**: squash-merge. `.claude/skills/batch-review/SKILL.md` kept its `[SQUASH]`
  variants and dropped the `[MERGE-COMMIT]` ones.
- **Review bots**: Copilot auto-reviews every PR; Codex/Claude review by request, expected on any
  non-trivial PR that won't get substantial human review otherwise. Filled into both §8 and the
  batch-review skill's bot roster.
- **Repo map** (`docs/repo-map.md`): kept — seeded with the one real greenfield boundary
  (owner-scoped data access, tracked as R-001) rather than padded with aspirational entries.
- **Caveman mode**: kept. Its body was appended to this file as `## Caveman Mode` below, since
  Claude Code reads `AGENTS.md` and not the per-tool files directly.
- **Skills**: kept both `batch-review` and `independent-commit-review` — operator confirmed both,
  even though `batch-review` won't earn its keep until a genuine multi-PR fan-out happens.
- **`.claude/skills/batch-review/SKILL.md` Phase 8 (Release)**: deleted at init — *at that time*
  no artifact/tag flow existed (deployment itself was undecided), so the phase had nothing to
  govern yet. Re-add if/when a release flow is designed. *(2026-08-11: the trigger has half-fired.
  #52 gave the repo an artifact flow — every merge to `main` publishes an image and moves
  `:latest` (§7) — but no release process on top of it: no `v*` tag has been cut and nothing
  consumes tags yet. Left deleted deliberately; re-add when tags actually become the deploy
  handle, not before.)*
- **Template lineage**: this repo is public, so per the init procedure the template's usual
  lineage block (template SHA, synced-through, last-checked) was omitted entirely — the pointer
  lives in the private `abradner/fleet` registry instead (row added/updated at init time:
  relationship "fresh init from keel", synced through `abd4b246569d96ee37f3b9ec48490a4816670295`,
  checked 2026-08-03).

### Sync to keel `8ffb118e` (2026-08-31)

Brought this repo up to the template's current head after four generations of drift. Taken:
`single-pr`, `park-context`/`resume-context`, `stack-integration-check`, and
`docs/pr-review-machinery.md` (new files); the stacked-PR-GA rewrite of `batch-review`; the
clean-worktree guard in `independent-commit-review`; §8's landing-changes, tooling-floor,
git-hygiene, shipping-flow and context/compaction rules; the merge-gate carve-outs; and the
`.claude/handoffs/` gitignore entry that `park-context` depends on.

Adapted rather than copied, in both directions:

- **§8's testing rules were merged, not replaced.** This repo's five-case "a revert that doesn't
  fail doesn't mean the test is good" diagnosis is local work with no template equivalent and is
  kept in full; the template's newer bullets (name-the-attacker, inference-is-not-diagnosis,
  watch-the-setup, mutants-must-compile) were added around it. The five-case block is flagged
  upstream as a backport candidate.
- **The bot roster now says what is true.** §8 and the batch-review roster named Claude as a
  reviewer; it has never posted a review on this repo. Verified against this repo's own PR history
  — Copilot and Codex both real, Claude removed rather than left as an unfalsifiable claim
  (meta-rule 1). The batch-review validation line was likewise stale ("no app code or CI exists
  yet, greenfield") and now describes the real gate.
- **`docs/rails-prometheus-metrics.md` deliberately not taken.** The template wrote that recipe up
  *from* this repo's own metrics work (and its three Rails siblings); importing it back would add a
  second description of a boundary this repo already implements, free to drift from the code.
- **No Template lineage block**, unchanged: this repo is public, and the pointer to a private
  template stays in the fleet registry only. The registry row is the sync record.

## Caveman Mode

Respond terse like smart caveman. All technical substance stay. Only fluff die.

Rules:
- Drop: articles (a/an/the), filler (just/really/basically), pleasantries, hedging
- Fragments OK. Short synonyms. Technical terms exact. Code unchanged.
- Pattern: [thing] [action] [reason]. [next step].
- Not: "Sure! I'd be happy to help you with that."
- Yes: "Bug in auth middleware. Fix:"

Switch level: /caveman lite|full|ultra|wenyan
Stop: "stop caveman" or "normal mode"

Auto-Clarity: drop caveman for security warnings, irreversible actions, user confused. Resume after.

Boundaries: code/commits/PRs written normal.
