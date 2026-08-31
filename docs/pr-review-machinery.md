# PR review machinery

> Shared reference for `.claude/skills/single-pr` and `.claude/skills/batch-review`. Both skills
> instruct you to read this. They may *name* a mechanic in passing so their own procedure reads
> straight through, but the detail lives here and only here — **where a skill and this file
> disagree, this file wins, and the skill is the bug.** Never grow a second copy of a rule in a
> skill.
>
> It covers the mechanics of getting a PR actually reviewed and actually verified — the parts that
> are identical whether you are shipping one PR or a stack of them. What differs between the two flows (when you react to feedback, and how the
> merge happens) stays in each skill.

Read this once per session, not once per PR.

## 1. Reviewers: know each one's trigger

Reviewers are not interchangeable and most do **not** fire on their own. Establish for each one
*what triggers it* and *what it is good for* before you need it.

> **The table below is the fleet's default roster, not this repo's — verify it before relying on
> it, and correct it at init.** A repo's steering doc once named a reviewer whose app had never
> been installed; PRs satisfied the letter of the rule while getting one bot pass instead of two,
> and nobody noticed for weeks. Confirm each bot has actually commented in *this* repo
> before counting it as a review surface, and check **all three surfaces** from §2 — a bot that only
> leaves inline or issue comments never appears in `pulls/<n>/reviews`, so a reviews-only check can
> report a reviewer as absent when it is working, or as present when it has only ever errored:
>
> ```bash
> for n in <recent PR numbers>; do
>   gh api repos/{owner}/{repo}/pulls/$n/reviews  --jq '.[].user.login'
>   gh api repos/{owner}/{repo}/pulls/$n/comments --jq '.[].user.login'
>   gh api repos/{owner}/{repo}/issues/$n/comments --jq '.[].user.login'
> done | sort -u
> ```
>
> Delete rows for reviewers this repo doesn't have.

| Reviewer | Trigger | Cost | Notes |
|---|---|---|---|
| **Copilot** | Balanced review automatically on every PR **created or promoted to ready**. Never on push. | Cheap — unrationed | A followup push needs an explicit re-request through the GitHub PR review mechanism, or you are reading a verdict on superseded code. |
| **Codex** | **Repo-configurable** — may auto-review on PR-open and draft→ready, or may review only when asked via a `@codex <prompt>` comment. Check its own "About Codex in GitHub" box on any past review, which states the repo's actual triggers. | Expensive — budget it | If auto-review is off, its absence is silent: nobody asks, it never reviews, and nothing looks wrong. Spend it on the largest coherent diff available; it takes a prompt, so aim it. |

Re-requesting Copilot through the API needs the literal `[bot]` suffix on the login:

```bash
gh api repos/{owner}/{repo}/pulls/<n>/requested_reviewers -X POST \
  -f 'reviewers[]=copilot-pull-request-reviewer[bot]'
```

Without the suffix it returns **422 "Reviews may only be requested from collaborators"** — which
reads like a permissions problem but is really a bad-login problem. Don't conclude from that 422
that the route is closed. `GET`-ing the PR back may show `requested_reviewers: []` even on success;
verify via the GraphQL timeline (`ReviewRequestedEvent`) instead.

Rules that hold for every reviewer:

- **Ask for comments only, never commits.** An agent pushing to your branch rewrites work under a
  review in progress.
- **A draft PR gets no *automatic* review** until the ready flip — trigger-on-ready reviewers do
  not fire, so a change can sit looking normal for an hour with nothing happening. An **explicitly
  requested** reviewer will review a draft, which is what makes `batch-review`'s draft-first
  aggregate pass work. Either way, verify a review actually arrived rather than assuming.
- Feedback typically lands ~5 minutes after the trigger; don't look before ~10. If a bot hasn't
  posted within 10 minutes of the trigger (or of the 👀 reaction appearing), assume it won't.
- **Verify the roster is actually installed** — the blockquote above is the check, not a formality.
- **In-session self-review is not an independent pass.** An author reviewing their own work is
  anchored — they already decided the tricky bits were fine while writing them. An independent
  pass by a reviewer with no memory of writing the code is a different instrument
  (`.claude/skills/independent-commit-review`, where a repo keeps it).

## 2. Harvest all three surfaces

They are separate API routes, and the substance is rarely in the one reached for first:

```bash
gh pr view <n> --json comments                     # issue comments
gh api repos/{owner}/{repo}/pulls/<n>/reviews      # review bodies
gh api repos/{owner}/{repo}/pulls/<n>/comments     # INLINE — usually where the findings are
```

Codex posts its findings as **inline comments** while its review *body* is a boilerplate template
with no content. Copilot additionally hides real findings inside a collapsed
`<details>Suppressed comments</details>` block.

**Never conclude "no findings" from an empty review body.** One batch was read body-only across six
PRs and reported clean; it was carrying 5 P1s and 8 P2s in inline comments, unread for two days,
including an agent-readable signing key and a migration that silently reopened an auth gate on
upgrade. Read the suppressed and low-confidence comments too — several were the best findings in
that batch.

**An unresolved thread re-anchors to the current head, so `commit_id` does not mean "reviewed
this commit".** After a push, an open review comment from three commits ago comes back with
`commit_id` equal to the new head while `original_commit_id` still points at the commit it was
actually written against. Filtering inline comments by `commit_id == HEAD` therefore reports stale
findings as fresh ones — and, worse, makes an absent re-review look like a delivered one. Establish
whether a reviewer has actually re-reviewed from the **review** record, not the comment records:

```bash
gh api repos/{owner}/{repo}/pulls/<n>/reviews \
  --jq '.[] | "\(.user.login) reviewed \(.commit_id[0:10])"'
```

(Observed on this template's own PR #5: four findings appeared to be current at the new head, all
four were round-one threads re-anchored, and the reviewer had not re-reviewed at all.)

Two more harvest traps:

- **A failed bot run looks like a clean one.** A Copilot error lands as a `COMMENTED` review whose
  body says it could not review, with zero inline comments; `gh pr view --json reviews` renders that
  identically to a real pass. Check body content and inline count.
- **Filter agent-posted bookkeeping replies out of the review record.** They post under the
  operator's credentials and masquerade as human reviews. Distinguish by `in_reply_to_id`, not
  author.

## 3. Triage by verifying

A finding is a claim, not a verdict — whether it came from a bot, a human, or your own earlier
session. Trace or reproduce it before acting. Ask whether the flagged path is actually reachable.
When a finding says code and docs disagree, work out which end is wrong before "fixing" either.

Sort each into: **fix now** / **defer to the tracker** / **decline with a stated reason**.

**Declining has to actually happen.** A round that accepts every finding is a warning sign, not a
good score. Reject anything that violates `AGENTS.md`, and say why — automated reviewers read that
file too.

Deferrals go to the repo's external tracker, never a PR-body table: a triage table goes stale
between rounds and vanishes on merge.

## 4. The round cap

**Three reactive rounds, then defer.** Past the cap, remaining findings are ticketed, not patched.

**If one small change draws three or more findings, revert it and ticket it** — it needs design
time, not another patch.

**The cap can arrive early.** When a round's findings are all in code the previous round wrote,
that is the cap arriving — regardless of the round count or how few files are in play. Three rounds
is a ceiling, not an allowance.

The cap exists because rounds introduce bugs. A measured batch ran seven reactive rounds with
finding counts 6 → 2 → 1 → 3 → 2 → 5 — not convergence: four of the five later rounds were fixing
defects a previous round's own fix had introduced. A separate repo independently recorded a "third
instance in this batch of a fix introducing the next round's finding" the same week. The PR that
added this very paragraph did it again: its round-2 fix introduced a round-3 P1 (a disposition
check written severity-blind, so a ticketed P1 would have satisfied the rule meant to block it),
and a second round-2 fix turned out not to work at all. Three rounds is a ceiling for a reason,
and docs-only changes are not exempt.

**Hitting the cap is not the same as stopping mid-air — exit through a declared closing round.**
The cap says stop *patching*, not stop *thinking*: when it fires (at three rounds, or early by the
rule above) with findings still open, say so in the PR and name that round the closing one. In it,
only P1/red blocks; everything else is ticketed with the review link, and nothing new is started.
This is an exit procedure, not another lap — an agent that reads the cap as "abandon the open
findings" leaves accepted work untracked on trunk, which is the failure the followup pre-flight
in `batch-review` Phase 7 exists to catch. (A sibling repo's six-round series landed this way. Its
own retrospective is the cheaper lesson: a schema-driven feature that draws that many rounds
needed a design pass up front, per the revert-and-ticket rule above.)

## 5. Never trust a green signal

Every one of these has produced a false clear for real:

| Signal | How it lies | The check that catches it |
|---|---|---|
| "Zero unresolved threads" | Reads identically whether feedback was addressed or never solicited | Verify a review was actually requested and delivered **for the current head commit** |
| "No new comments" | Suppressed/collapsed blocks hide real findings under a clean summary | Expand and read the raw review payload via `gh api`, not the summary state |
| New test passing on first run | May be passing against unfixed code | Revert-and-confirm: watch it fail without the fix |
| Green CI run | Path filtering may have skipped the half of the suite your change lives in | Check **which jobs actually ran**, not the rollup colour |
| A merge command that returned | Stacked merges are asynchronous; rules are evaluated when the merge runs | Poll to a terminal status; `enqueued` is not `merged` |

Two related habits:

- **Inference from a plausible nearby cause is not diagnosis.** During a platform outage, a red main
  was attributed to the outage's known error; the outage was real but unrelated, and the actual job
  failure had been there all along. Read the actual failure.
- **Verify propagated fixes by content** (grep, or run the test), never by `--stat`.

## 6. Merging

The merge gate lives in `AGENTS.md` §8 — **read it there before merging anything.** `AGENTS.md` is
canonical for it, exactly as this file is canonical for the mechanics above. The one-line orientation
is that the baseline is a live operator go-ahead and that agents must not propose loosening it; every
qualification on that — what a conditional grant is, what a session carve-out covers, what does not
count — is in §8 and is deliberately not duplicated here.

## 7. Mechanical gotchas

Small, recurring, and each one wastes a round when it bites:

- **Replying to a review thread does not resolve it.** Resolution is the `resolveReviewThread`
  GraphQL mutation, and the thread ID must go in as a bound variable
  (`gh api graphql -F threadId=...`), not string-interpolated into the query — the interpolated
  form fails with "malformed" but can *look* like it worked.
- **`gh api -f in_reply_to=<id>` 422s.** That field is numeric: use `-F` (typed), not `-f`
  (string).
- **Multi-line commit messages go through `git commit -F <file>`, never inline `-m "..."`.** An
  embedded quote closes the shell string early and the remainder leaks as positional args,
  surfacing as a baffling `error: pathspec 'X' did not match any file(s)` that says nothing about
  quoting.
- **`git merge-base --is-ancestor` cannot tell you whether work landed via a squash merge.** The
  squash is a new commit with no ancestry relationship to the branch's commits — check by content
  (diff the files, grep for the change), not by ancestry.

---

**Maintenance note.** This file is the canonical copy. The account-wide standalone
`~/.claude/skills/batch-review/SKILL.md` deliberately carries its own self-contained duplicate,
because it runs in repos that have no keel `AGENTS.md` and no `docs/` — it is regenerated from
keel's `batch-review`, so changes here reach it by regeneration, not by reference. That copy is
expected to lag; check it when this file changes materially.
