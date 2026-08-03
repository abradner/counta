---
name: batch-review
description: Batch PR shipping workflow - fan out a body of work as a stack of small atomic single-commit PRs (interstitials, from base to cap), let CI and automated reviewers run immediately but treat all feedback as write-only until the whole batch is in, then synthesise the feedback in aggregate, ship all reactive work as ONE followup PR stacked on the cap, resolve interstitial comments as "fixed in the followup" or "not relevant", merge interstitials bottom-up and the followup last. Use this whenever the user wants to review open PRs holistically or in aggregate, process accumulated bot/agent review comments across several PRs, ship a "review feedback batch" or followup PR, or mentions their overnight/fired-off batch of work - even if they don't say "batch review" explicitly. ALSO use at fan-out time, when the user asks to build a planned body of work as small/carefully-factored/stacked PRs. This is a deliberately different, opt-in mode for a genuine multi-PR fan-out, not this repo's default single-PR flow.
---

# Batch review

The core bargain: **feedback is write-only until the whole batch is synthesised.** CI and the bots
run immediately on every PR and comments accumulate freely — but nothing responds to them and no
reviewed branch is rewritten until the synthesis pass. All reactive work ships as one followup PR.

Why: reacting piecemeal across several in-flight PRs creates real churn — branches rewritten under
open reviews, repeated rebase/conflict cycles, reviewer attention fragmented across many small
live threads instead of one synthesis pass. The default single-PR flow (react immediately, merge
when green) remains correct for one PR at a time; this skill exists for the multi-PR case only.

## Terminology

| Term | Meaning |
|---|---|
| Interstitial | A single-commit PR in the proactive stack |
| Base / Cap | The bottom-most / top-most interstitial |
| Followup | The one N-commit reactive PR stacked on the cap — the batch's only live-feedback surface and its release gate |
| Stack object | GitHub stacked-PR beta entity (stacked flavour only) |

## Repo specifics

- **Validation commands**: `bundle exec rspec` for the full suite, prefixed with mise's Ruby
  (`mise exec --`) if not already active in the shell. No app code or CI exists yet (greenfield) —
  revisit this line once the Rails app is scaffolded and a linter (if any) is adopted.
- **Bot roster**: Copilot auto-reviews every PR — cheap, unrationed. Codex/Claude review by
  request only — expected to actually be invoked whenever a non-trivial PR won't otherwise get
  substantial human review before merge.
- **Merge strategy**: squash-merge. Rules below keep their `[SQUASH]` variant; `[MERGE-COMMIT]`
  variants have been removed.
- **Deferral convention**: GitHub Issues. File non-blocking findings there, not in a PR-body table.

## Phase 1 — Flavour probe

Probe whether GitHub's stacked-PR beta (`gh stack`) is enrolled and working for this repo; pick
**stacked** or **manual** flavour accordingly and record the choice in the batch's tracking note.
A batch finishes in the flavour it started; the only mid-batch transition allowed is stacked →
manual (via unstacking), never the reverse. Re-probe every batch — enrollment and beta behavior
change. Treat any stacked-flavour tooling claims as recorded observation, not guarantee: sibling
repos observed `gh stack sync` reporting "✓ synced" without pushing, and stack commands silently
operating against a stale local main ref inside worktrees while printing success.

## Phase 2 — Self-review before fan-out

Before any PR opens, run one pointed self-review question per branch — "what did this change make
newly risky?" — delegated to a cheap review subagent, findings fixed in the commit itself.
Evidence for why this is worth the cost: the same finding surfaced before opening costs a
`git commit --amend`; the same finding after fan-out costs a reactive round, and rounds introduce
bugs (see Provenance).

## Phase 3 — Fan-out

- One commit per interstitial, opened ready-for-review immediately (trips auto-reviewers once,
  early, while reaction is still cheap to withhold).
- Every PR body carries a machine-scannable batch block, so the ground rules survive even when
  this skill doesn't trigger and AGENTS.md goes unread:

  ```
  ## Batch
  Batch: <name> | Flavour: manual|stacked | Position: N of M
  Stacked on: #<parent> | Feedback: write-only until synthesis — see followup PR
  Merge: bottom-up after followup approval, operator-gated
  ```

- Never guess PR numbers; never leave placeholder references live.

## Phase 4 — Bake

Interstitial CI red is tolerated (the followup fixes it). Exactly one showstopper bar justifies
touching an interstitial mid-bake: **an irreversible action on merge** — a destructive migration,
an unrecallable external side effect. Everything else waits.

- If main moves under the stack: restart affected branches from fresh main after their parents
  land; never stack new commits on pre-merge history.
- A showstopper fix injected low in the stack must be explicitly propagated into each child —
  squash does not preserve the ancestry that would reunify it.

**Driving phase transitions**: subscribe to PR/CI events and react when they arrive; pair the
subscription with a bounded fallback timer (order of ~30 min for a full stack's reviews, ~10 min
for a single re-solicited review) so a bot no-show can't stall an unattended batch. That fallback
is this workflow's single named exception to event-driven monitoring, not a license for scheduled
polling elsewhere.

## Phase 5 — Synthesis

- Harvest every comment on every PR via `gh api` — threads, reviews, and top-level comments.
- Filter agent-posted bookkeeping replies out of the review record: they post under the operator's
  credentials and masquerade as human reviews. Distinguish by `in_reply_to_id`, not author.
- Triage by verifying: reproduce claims, check citations, apply AGENTS.md's "a finding is a claim,
  not a verdict." Sort into: fix in followup / deferral to tracker / decline with stated reason.
- Add one aggregate pass of your own across the full stack diff — cross-PR interactions are
  structurally invisible to per-PR reviewers.

## Phase 6 — The followup PR

- Open as a **draft targeting main** so its diff is the whole stack — spend one budgeted
  aggregate bot review there — then **retarget to the cap** before marking ready, so per-PR
  reviewers see only the reactive delta.
- Maintain a `## Review focus` section in the body, restated each round.
- **Hard cap: three reactive rounds.** Past the cap, remaining findings are deferred to the
  tracker, not patched. If one small change draws three or more findings, revert it and ticket
  it — it needs design time, not another patch. (See Provenance for why the cap exists.)
- **Never trust an aggregate review signal.** Known false-green patterns, each observed for real:

  | Signal | How it lies | The check that catches it |
  |---|---|---|
  | "Zero unresolved threads" | Reads identically whether feedback was addressed or never solicited | Verify a review was actually requested and delivered for the current head commit |
  | "No new comments" | Suppressed/collapsed comment blocks hide real findings under a clean summary | Expand and read the raw review payload via `gh api`, not the summary state |
  | New test passing on first run | May be passing against unfixed code | Revert-and-confirm: watch it fail without the fix |
  | Green CI run | Path filtering may have skipped the half of the suite your change lives in | Check which jobs actually ran, not the rollup color |

## Phase 7 — Merge the stack

- **Operator gate: never start this phase without the operator explicitly saying to merge now.**
  A synthesis pass, a green followup, and an auto-mode session default are not that signal. If the
  stack is ready, say so and stop.
- Merge bottom-up. Before deleting a merged branch, verify every child PR has already been
  retargeted — deleting a base branch races the platform's auto-retarget and has closed child PRs
  mid-train. Retarget first, confirm, then delete.
- Followup merges last: squash-merged.
- If a child PR does get closed by a race: reopen against the corrected base immediately; its
  commits are intact on the branch.

## Rules of thumb

One commit per interstitial. Open ready-for-review immediately. Nothing answers feedback until
synthesis. Showstopper bar = irreversible-on-merge only. One followup PR carries all reactive
work. Three reactive rounds, then defer. Verify aggregate signals; never trust the rollup.
Operator says "merge" — nothing else counts. Bottom-up, retarget before delete, tag once.

## Where these rules came from

Ported across a fleet of sibling repos and corrected against real batches in each. Keep this
section when adapting: add to it rather than replacing it — the value is in the accumulated
evidence, not in any single batch.

- The write-only rule exists because piecemeal feedback batches once rewrote main under a
  still-open stacked PR and killed it.
- The three-round cap exists because a measured batch ran seven reactive rounds with finding
  counts 6 → 2 → 1 → 3 → 2 → 5 — not convergence: four of the five later rounds were fixing
  defects a previous round's own fix had introduced. A separate repo independently recorded a
  "third instance in this batch of a fix introducing the next round's finding" the same week.
- The self-review-before-fan-out gate exists because of the same data: findings are an order of
  magnitude cheaper before the stack exists.
- The bot-budget asymmetry (unrationed cheap reviewer, budgeted expensive one) comes from a
  measured split: the cheap bot caught 6/6 of a mechanical bug class; every expensive-bot finding
  that mattered was cross-file. Spend the budget on aggregate diffs.
- The retarget-before-delete rule exists because `gh pr merge --delete-branch` closed a child PR
  in a live merge train when branch deletion raced GitHub's auto-retarget.

(Append this repo's own batch outcomes here as they accumulate.)
