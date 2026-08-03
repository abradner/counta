# keel

> 🤖 **AI Agents:** if this repo was created from the keel template and hasn't been initialized
> yet, read [`TEMPLATE_INIT.md`](TEMPLATE_INIT.md) and run the init procedure. Otherwise read
> [`AGENTS.md`](AGENTS.md) — this README is for humans.

A template repository providing a baseline for **agentic steering**: the documents, skills, and
hygiene files that make a repo a good working environment for AI coding agents from the first
session.

Synthesized from steering docs iterated across a fleet of real repos — the patterns here survived
months of near-daily agent-driven development, and the load-bearing rules cite the incidents that
motivated them.

## What's in the box

| Path | What it is |
|---|---|
| `AGENTS.md` | The canonical steering doc: purpose & principles (with a tripwire protocol for conflicts), portable working rules (pre-filled), and repo-specific slots (`[KEEL:FILL]` placeholders). |
| `CLAUDE.md` | 8-line import stub pointing at `AGENTS.md` — one canonical file, no drift. |
| `TEMPLATE_INIT.md` | Agent-driven init procedure: interview, fill, prune, record, self-delete. |
| `docs/repo-map.md` | Living boundary map: surfaces, trust boundaries, cross-cutting flows, risk register. Opt-out (keep by default) — its value compounds with complexity and nobody retrofits one later. |
| `.claude/skills/batch-review/` | Multi-PR fan-out shipping workflow (write-only feedback until synthesis, hard round cap, operator-gated merge). Parameterized — merge strategy and bot roster are fill-ins. |
| `.claude/skills/independent-commit-review/` | Adversarial fresh-eyes pre-push review: one cold subagent per commit, revert-and-confirm verification. |
| `.cursor/`, `.windsurf/`, `.clinerules/`, `.opencode/`, `.github/copilot-instructions.md` | Optional tone module ("caveman mode") fanned out to each tool's convention path, each also pointing back at `AGENTS.md`. Prunable at init. |
| `LICENSE` | Apache-2.0 (swap or remove at init). |
| `.gitignore`, `.editorconfig`, `mise.toml` | Universal hygiene baselines; init extends them per stack. |

## Creating a repo from this template

**Preferred:** GitHub's *Use this template* → creates a fresh repo with a single initial commit
and no shared history. Note: this template is private; the "generated from" attribution on a
public downstream repo is only visible to users with read access to the template, so nothing
leaks — but if you want zero pedigree, use the copy path.

**Alternative:** plain file copy into a fresh `git init` (optionally omitting modules by hand,
though the init procedure handles pruning either way).

Then open the new repo in an agent session and say: **"run the template init"** — the agent
follows `TEMPLATE_INIT.md`, interviews you, fills every placeholder, prunes what doesn't apply,
records the pruning rationale in `AGENTS.md`'s Adaptation Record, and deletes the init file.

## Maintaining the template

Improvements discovered downstream should flow back here — but as judgment, not copying: verify
each candidate against what the template actually claims, and keep `AGENTS.md`'s maintenance
meta-rules (especially "a rule everyone knows is wrong is worse than no rule") applying to this
repo too.
