# Counta

> 🤖 AI Agents: read AGENTS.md instead. This README is for humans.

Counta counts the clicks on measured-dose pen injectors (e.g. Novo Nordisk's
FlexTouch) so you don't have to keep a paper tally. It tracks what's left in
the pen, warns you when the pen will expire before you finish it, and can put
your dose schedule in your calendar.

**Your pen and dose data is encrypted on your device.** The account is an
anonymous ID — no email, no name, no password — and you sign in with a
passkey, which is also what produces the encryption key. counta.click stores
ciphertext it has no way to open.

| Dose screen | Pen setup | Recovery kit |
|---|---|---|
| ![Dose screen](docs/screenshots/06-dose-screen.png) | ![Pen setup](docs/screenshots/05-pen-setup.png) | ![Recovery kit](docs/screenshots/03-recovery-kit.png) |

**Status:** first working cut. Passkey-encrypted accounts, pen setup and dose
tracking, calendar export, archiving, and delete-everything all work. Recall
matching and push notifications are designed but not built — the UI says so
where it matters.

## Why it's built this way

- **Clicks are the unit that matters.** Not every pen maps one click to one
  dose unit (a Tresiba U200 delivers 2 U per click), so counta stores clicks
  and derives the milligrams or units for display. The readout always leads
  with clicks — the thing you actually do to the pen.
- **Some pens have no readable window.** Wegovy's counter is a blank scroll
  between 0 and full, so the click count is the *only* measure. Copy for those
  pens never implies the window shows a number.
- **Privacy is structural, not a promise.** Dose history lives in a single
  encrypted blob per pen rather than a row per dose, because row counts and
  timestamps would reconstruct your dosing rhythm on their own.
- **Losing your keys means losing your data.** That's the deliberate cost of
  the operator being unable to read it, and the app says so plainly before you
  create an account.
- **It counts; it doesn't advise.** All copy is descriptive, never
  prescriptive — a dose calculator that tells you what to take drifts into
  regulated medical-device territory.

The reasoning behind the code's shape is in
[`docs/architecture.md`](docs/architecture.md), the data design in
[`docs/data-privacy.md`](docs/data-privacy.md), and a screen-by-screen tour in
[`docs/ui-tour.md`](docs/ui-tour.md).

## Stack

Ruby on Rails, PostgreSQL, RSpec, vanilla ES modules over importmap. See
`AGENTS.md` §3 for the stack and §6 for setup and dev commands.

```sh
docker compose up -d db
mise install && mise exec -- bundle install
mise exec -- bundle exec rails db:prepare db:seed
mise exec -- bundle exec rails server -d -b 0.0.0.0 -p 25425
mise exec -- bundle exec rspec
```

## License

Apache-2.0 — see `LICENSE`.
