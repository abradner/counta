# Counta

> 🤖 AI Agents: read AGENTS.md instead. This README is for humans.

Counta is a simple, secure, easy-to-use tool for counting clicks/doses on measured-dose pens (e.g.
Novo Nordisk's FlexTouch). It exists to replace manual tally-keeping with something trivially easy
to use, accessible by default, and built on a privacy-first data model — a user's own data is
opaque to everyone but them.

**Status:** first working cut — passkey (WebAuthn + PRF) end-to-end-encrypted accounts, pen
setup/dose tracking ported from the design prototype, calendar (ICS) export, and full
delete-everything. See `docs/data-privacy.md` for the data & privacy design.

## Stack

Ruby on Rails, PostgreSQL, RSpec. See `AGENTS.md` §3 for the stack and §6 for setup/dev
commands.

## License

Apache-2.0 — see `LICENSE`.
