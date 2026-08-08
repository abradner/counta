require "rails_helper"

RSpec.describe "ICS export and account panel", type: :system do
  before do
    load Rails.root.join("db/seeds.rb")
    visit "/"
    add_virtual_authenticator
    sign_up_through_first_run
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    save_pen
  end

  # icsPreview mints/bumps calendarUid + calendarSequence and persists them,
  # exactly like a real export button press (test_hooks.js). now_ms, if
  # given, pins the dosing-time proxy's "moment of export" so specs can
  # assert exact DTSTART/DTEND without racing the real clock.
  def ics_preview(now_ms = nil)
    page.evaluate_async_script(
      "window.countaTest.icsPreview(arguments[0]).then(arguments[1])", now_ms
    )
  end

  # A fixed local time-of-day, built from the BROWSER's own Date so it's
  # immune to host/Ruby timezone differences (same reasoning as "today" in
  # the anchoring spec below). :14 rounds cleanly down to :00 — see
  # spec/system/dosing_time_spec.rb for the proxy's boundary behaviour.
  def local_time_ms(hour, minute)
    page.evaluate_script("(() => { const d = new Date(); d.setHours(#{hour}, #{minute}, 0, 0); return d.getTime(); })()")
  end

  it "builds a deterministic client-side ICS schedule" do
    log_dose # 8 clicks → 36 full doses remain, schedule anchors on the dose date

    ics = ics_preview(local_time_ms(9, 14)) # rounds to 09:00

    expect(ics).to include("BEGIN:VCALENDAR")
    # Timed 5-minute dose event with an immediate alarm (#14), not all-day —
    # an all-day event can't carry a time and most clients never alert on it.
    expect(ics).to match(/DTSTART:\d{8}T090000\r\n/)
    expect(ics).to match(/DTEND:\d{8}T090500\r\n/)
    expect(ics).to include("BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:PT0M", "END:VALARM")
    # 288 clicks left at 8 clicks/dose = 36 doses, weekly.
    expect(ics).to include("RRULE:FREQ=DAILY;INTERVAL=7;COUNT=36")
    # Wegovy is a progress-style pen: the calendar entry must not imply the
    # window shows a number (docs/design-notes.md).
    expect(ics).to include("Dose day — Wegovy: dial 8 clicks (≈ 0.26 mg)")
    expect(ics).to include("the window shows no number")
    expect(ics).not_to include("counter will show")
    expect(ics).to include("isn’t medical advice")
    expect(ics).to include("Buy more Wegovy")
    # The "buy more" nudge is for the week, not a moment — it stays all-day.
    expect(ics).to match(/UID:.+-refill@counta\.click\r\nSEQUENCE:1\r\nDTSTAMP:[^\r]+\r\nDTSTART;VALUE=DATE:\d{8}\r\n/)

    # First export: SEQUENCE starts at 1 (RFC 5545 §3.8.7.4), once per event.
    expect(ics.scan("SEQUENCE:1").length).to eq(2)

    # The schedule never touched the server in plaintext: nothing about it is
    # queryable. (calendarUid/calendarSequence live in the blob too, but as
    # an opaque id and an integer — neither is the literal string "RRULE".)
    expect(Pen.sole.blob).not_to include("RRULE")
  end

  # Regression for the most dangerous defect found in review: on a Tresiba
  # U200 one click delivers 2 U, so a calendar entry reading "counter set to
  # 5 clicks" invites the user to dial until the window shows 5 — half their
  # basal insulin. The exported text is read months later without the app
  # open, so it has to be unambiguous on its own.
  it "tells numeric-counter pens what the window will show, not the click count" do
    click_button "Edit this pen’s data"
    select "Tresiba 200 U/mL (3 mL · 600 U)", from: "f-product"
    save_pen

    expect(find("#readout-big").text).to eq("5 clicks")
    expect(find("#readout-sub").text).to eq("counter will show 10")

    ics = ics_preview
    expect(ics).to include("Dose day — Tresiba: dial 5 clicks — the counter will show 10 U")
    # The click count must never be presented as the number on the window.
    expect(ics).not_to include("counter will show 5")
    expect(ics).not_to include("counter set to")
    # The alarm's own DESCRIPTION carries the same unambiguous text — some
    # clients drop an alarm whose DESCRIPTION is missing, so it isn't blank.
    expect(ics).to include("DESCRIPTION:Dose day — Tresiba: dial 5 clicks — the counter will show 10 U")
  end

  # Regression: the export anchored on the last-ENTERED dose, so logging a
  # backdated dose after a recent one started the whole reminder series (and
  # the refill event) a cycle early.
  it "anchors the schedule on the latest dose date, not the last one entered" do
    log_dose # today

    # "Today" must come from the BROWSER: dose dates are local calendar dates,
    # while Ruby's Date.current is UTC, and on a UTC+10 box just after midnight
    # those are different days (AGENTS.md §9.6 in spec form).
    today = Date.parse(page.evaluate_script(
      "(d => `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`)(new Date())"
    ))
    backdated = (today - 21).iso8601
    page.execute_script(
      "document.getElementById('f-date').value = arguments[0];" \
      "document.getElementById('f-date').dispatchEvent(new Event('change', { bubbles: true }))",
      backdated
    )
    click_button "Dose now"
    within("#confirm-dlg") { click_button "Yes, I dosed" }
    expect(page).to have_css("#history li", minimum: 2, wait: 10)

    ics = ics_preview(local_time_ms(9, 0))
    # Weekly pen dosed today: the series starts a week from TODAY, not a week
    # after the backdated entry (which is already in the past).
    expect(ics).to include("DTSTART:#{(today + 7).strftime("%Y%m%d")}T090000")
    expect(ics).not_to include("DTSTART:#{(today - 14).strftime("%Y%m%d")}T090000")
  end

  # Re-export shouldn't duplicate, gap 1 (#14): without a growing SEQUENCE, a
  # client may ignore an update to an existing UID (RFC 5545). The UID itself
  # must stay put across exports — only SEQUENCE should move.
  it "bumps SEQUENCE on every export while keeping the same event UID" do
    log_dose

    first = ics_preview(local_time_ms(9, 0))
    uid_line = first[/UID:.+-dose@counta\.click/]
    expect(first).to include("#{uid_line}\r\nSEQUENCE:1")

    second = ics_preview(local_time_ms(9, 0))
    expect(second).to include(uid_line)
    expect(second).to include("#{uid_line}\r\nSEQUENCE:2")

    data = page.evaluate_async_script(<<~JS)
      window.countaTest.rows()
        .then(rows => window.countaTest.decryptRow(rows[0]))
        .then(arguments[0]);
    JS
    expect(data["calendarSequence"]).to eq(2)
    expect(uid_line).to include(data["calendarUid"])
  end

  # Re-export shouldn't duplicate, gap 2 (#14): calendarUid/calendarSequence
  # live in the encrypted blob precisely so they survive a pen row being
  # recreated. That's meaningless if an ordinary settings edit — which
  # rebuilds the whole blob (savePenForm) — silently drops them.
  it "preserves calendarUid/calendarSequence across a plain pen-settings edit" do
    log_dose
    first = ics_preview(local_time_ms(9, 0))
    uid_line = first[/UID:.+-dose@counta\.click/]
    expect(first).to include("SEQUENCE:1")

    click_button "Edit this pen’s data"
    save_pen(batch: "EDITEDBATCH")

    second = ics_preview(local_time_ms(9, 0))
    expect(second).to include(uid_line)
    expect(second).to include("SEQUENCE:2")
  end

  # A dose at 18:00 has to stay 18:00 across a DST transition (#14) — a UTC
  # instant wouldn't. The proxy takes only the hour/minute off the rounded
  # export moment and applies them to the (separately computed) anchor date,
  # so it can't inherit "now"'s UTC offset even when the anchor date sits on
  # the other side of a clock change from "now" itself.
  it "keeps the dosing-time proxy's local hour stable across a DST transition" do
    page.driver.browser.page.command("Emulation.setTimezoneOverride", timezoneId: "America/New_York")

    # Dosed the Monday after the 2026 US spring-forward (March 8) — the next
    # weekly reminder (2026-03-16) sits comfortably inside EDT.
    page.execute_script(
      "document.getElementById('f-date').value = arguments[0];" \
      "document.getElementById('f-date').dispatchEvent(new Event('change', { bubbles: true }))",
      "2026-03-09"
    )
    click_button "Dose now"
    within("#confirm-dlg") { click_button "Yes, I dosed" }
    expect(page).to have_css("#history li", minimum: 1, wait: 10)

    # "Now" (the export moment the proxy rounds) is BEFORE the transition, in
    # EST — built in-browser so the overridden zone interprets it.
    now_ms = page.evaluate_script("new Date(2026, 2, 1, 18, 0, 0).getTime()")
    ics = ics_preview(now_ms)

    # If the code had carried now's UTC offset instead of just its wall-clock
    # hour, this would read 17:00 or 19:00 instead of 18:00.
    expect(ics).to include("DTSTART:20260316T180000")
    expect(ics).to include("DTEND:20260316T180500")
  end

  it "lists passkeys and deletes the account with full cascade" do
    log_dose
    account = Account.sole

    find("#account-btn").click
    expect(page).to have_css("#passkey-list li", count: 1)
    expect(find("#acct-id").text).to eq(account.id)

    click_button "Delete account & all data"
    within("#delete-dlg") { click_button "Delete everything" }
    expect(page).to have_button("Create account", wait: 10)

    expect(Account.count).to eq(0)
    expect(WebauthnCredential.count).to eq(0)
    expect(Pen.count).to eq(0)
  end
end
