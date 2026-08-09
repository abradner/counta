# Next-dose forecast (issue #37): two facts about the user's own schedule on
# the dose screen — when the next dose falls due, and what it will be.
#
# The day comes from the last dose plus the pen's cadence. The TIME comes from
# #14's proxy, now informed: pressing "Dose now" is someone dosing as they
# press it, so that moment is rounded to the half hour and kept with the dose,
# and the forecast reads it back. With no observed time yet it falls back to
# the clock right now and says so. The calendar export calls the same function
# on the same entries, which is #37's requirement that the two never disagree.
require "rails_helper"

RSpec.describe "Next-dose forecast", type: :system do
  WEGOVY_F = "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)".freeze
  PRESET_F = "Novo Nordisk published escalation (TGA product information, revised 22 Jun 2026)".freeze

  before do
    load Rails.root.join("db/seeds.rb")
    visit "/"
    add_virtual_authenticator
    sign_up_through_first_run
  end

  def browser_today
    Date.parse(page.evaluate_script(<<~JS))
      (() => { const d = new Date();
        return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; })()
    JS
  end

  def dose_on(date, clicks = 8, pen_index = 0)
    page.evaluate_async_script(<<~JS, date.iso8601, clicks, pen_index)
      window.countaTest.appendDoseTo(arguments[2], arguments[0], arguments[1]).then(arguments[3]);
    JS
  end

  def reopen
    visit "/"
    click_button "Unlock with passkey"
    expect(page).to have_css("#dose-card:not([hidden])", wait: 15)
  end

  # The negative control, and a decision worth pinning: a pen with no doses
  # renders NO forecast at all. There is nothing to count forward from, and the
  # history list directly below already says "No doses yet" — a second empty
  # state would be noise. The readout assertion is what stops this passing
  # because the whole screen broke.
  it "says nothing at all until there is a dose to count from" do
    select WEGOVY_F, from: "f-product"
    save_pen(batch: "FRESH", expiry: "2027-06")

    expect(page).to have_css("#forecast", visible: :hidden)
    expect(find("#readout-big")).to have_text("8 clicks")
    expect(find("#history").text).to include("No doses yet")
  end

  describe "a pen with no plan" do
    before do
      select WEGOVY_F, from: "f-product"
      save_pen(batch: "NP", expiry: "2027-06")
    end

    it "counts one cadence forward from the last dose" do
      last = browser_today - 2
      dose_on(last, 8)
      reopen

      # Weekly pen: due seven days after the last dose. The datetime attribute
      # is the assertion — the visible text is locale-formatted and would
      # differ between this machine and CI (AGENTS.md §9.9).
      expect(find("#forecast-due .forecast-date")[:datetime]).to eq((last + 7).iso8601)
      expect(find("#forecast-due").text).to start_with("Your next dose is due")
    end

    it "offers the last dose's amount, saying plainly that's what it is" do
      dose_on(browser_today - 1, 15)
      reopen

      # Said as a repeat, never as a schedule the user never set up (#37).
      expect(find("#forecast-amount").text).to eq("Same as your last dose, that’s 15 clicks · ≈ 0.49 mg.")
    end

    it "follows the pen's own cadence rather than assuming a week" do
      select "＋ Add a pen", from: "chip"
      select "Tresiba 200 U/mL (3 mL · 600 U)", from: "f-product"
      save_pen(batch: "TR", expiry: "2028-01")
      last = browser_today - 3
      dose_on(last, 10, 1)
      reopen
      # The switcher label carries a live percentage, so match the pen rather
      # than a number that shifts with every dose.
      find("#chip").find("option", text: /\ATresiba/).select_option

      # Daily insulin: tomorrow relative to the last dose, not next week.
      expect(find("#forecast-due .forecast-date")[:datetime]).to eq((last + 1).iso8601)
    end
  end

  describe "a pen following a plan" do
    it "gives the plan's amount rather than repeating the last dose" do
      select WEGOVY_F, from: "f-product"
      select PRESET_F, from: "f-plan"
      save_pen(batch: "PL", expiry: "2027-06")
      log_dose

      expect(find("#forecast-amount").text).to eq("Your plan puts it at 8 clicks · ≈ 0.26 mg.")
      expect(find("#forecast-due .forecast-date")[:datetime]).to eq((browser_today + 7).iso8601)
    end

    it "forecasts the step up, not a repeat, on the last dose of a step" do
      # The case #37 names: someone finishing week 4 of 0.25 mg should see
      # next week's 0.5 mg here, not a flat repeat of what they just took.
      select WEGOVY_F, from: "f-product"
      select PRESET_F, from: "f-plan"
      select "I’m taking 0.25 mg now", from: "f-plan-progress"
      fill_in "f-plan-prior", with: 3
      save_pen(batch: "STEP", expiry: "2027-06")
      expect(find("#plan-line").text).to include("1 more dose at this amount")

      log_dose # completes the 0.25 mg step

      expect(find("#forecast-amount").text).to eq("Your plan puts it at 15 clicks · ≈ 0.49 mg.")
    end

    it "counts forward from the plan's last dose after a pen swap" do
      select WEGOVY_F, from: "f-product"
      select PRESET_F, from: "f-plan"
      # The plan has to have been running before the dose below, or that dose
      # predates it and correctly counts for nothing (#21's start-date filter).
      page.execute_script(
        "document.getElementById('f-plan-start').value = arguments[0];" \
        "document.getElementById('f-plan-start').dispatchEvent(new Event('change', { bubbles: true }))",
        (browser_today - 30).iso8601
      )
      save_pen(batch: "PENA", expiry: "2027-06")
      last = browser_today - 2
      dose_on(last, 8)
      reopen
      click_button "Edit this pen’s data"
      click_button "Archive this pen"
      expect(page).to have_css("#archived-note:not([hidden])", wait: 10)

      select "＋ Add a pen", from: "chip"
      select WEGOVY_F, from: "f-product"
      select "Continue “Novo Nordisk published escalation” from your other pen", from: "f-plan"
      save_pen(batch: "PENB", expiry: "2028-01")

      # The new pen has no history of its own; the dose it counts forward from
      # is on the pen that was just archived, and the plan is what links them.
      expect(find("#forecast-due .forecast-date")[:datetime]).to eq((last + 7).iso8601)
    end

    it "falls back to the last dose once the ladder is finished" do
      select WEGOVY_F, from: "f-product"
      select PRESET_F, from: "f-plan"
      save_pen(batch: "DONE", expiry: "2027-06")
      page.evaluate_async_script(<<~JS)
        (async () => {
          const [row] = await window.countaTest.rows();
          const data = await window.countaTest.decryptRow(row);
          data.plan = { ...data.plan, priorDoses: 5,
                        steps: [ { units: 0.25, doses: 1, sourceLabel: null } ] };
          await window.countaTest.writeRow(row, data);
        })().then(arguments[0])
      JS
      reopen
      log_dose

      # A finished ladder has nothing further to say, so the forecast answers
      # the same way an unplanned pen does rather than inventing a third state.
      expect(find("#plan-line").text).to include("every step recorded")
      expect(find("#forecast-amount").text).to start_with("Same as your last dose")
    end
  end

  # Pressing "Dose now" is someone dosing as they press it — a strictly better
  # observation than #14's export-click proxy, and the only one counta can get
  # without asking a question nobody wants (two-taps rule).
  describe "the time of day" do
    # Empty string for "no time recorded": an array containing null does not
    # survive the CDP round trip intact, and [] reads the same as "no doses".
    def stored_times
      page.evaluate_async_script(<<~JS)
        window.countaTest.rows()
          .then(rows => window.countaTest.decryptRow(rows[0]))
          .then(data => data.history.map(h => h.time || ""))
          .then(arguments[0]);
      JS
    end

    def rounded_now
      ms = page.evaluate_script("window.countaTest.roundToNearestHalfHour(Date.now())")
      page.evaluate_script(<<~JS, ms)
        (() => { const d = new Date(arguments[0]);
          return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; })()
      JS
    end

    before do
      select WEGOVY_F, from: "f-product"
      save_pen(batch: "TIME", expiry: "2027-06")
    end

    it "keeps the moment a dose was recorded, and forecasts at that time" do
      log_dose
      recorded = stored_times.reject(&:empty?).first
      expect(recorded).to match(/\A\d{2}:\d{2}\z/)
      expect(recorded).to eq(rounded_now) # rounded to the half hour, not raw

      # Asserted on the machine-readable attribute: the rendered text is a
      # locale clock format and differs between this box and CI (§9.9).
      expect(find("#forecast-due .forecast-time")[:datetime]).to eq(recorded)
      # ...and stated as fact, not as the guess wording.
      expect(find("#forecast-due").text).not_to include("a guess")
    end

    it "prefers an observed time over the clock" do
      log_dose
      # Deliberately a slot the clock is not currently in: moments after a
      # dose, the stored time and the rounded present are the same half hour,
      # so a spec that only checks "they match" proves nothing about which
      # source won (AGENTS.md §9.10).
      distinct = rounded_now == "06:30" ? "18:30" : "06:30"
      page.evaluate_async_script(<<~JS, distinct)
        (async () => {
          const [row] = await window.countaTest.rows();
          const data = await window.countaTest.decryptRow(row);
          data.history[0].time = arguments[0];
          await window.countaTest.writeRow(row, data);
        })().then(arguments[1])
      JS
      reopen

      expect(find("#forecast-due .forecast-time")[:datetime]).to eq(distinct)
      expect(find("#forecast-due").text).not_to include("a guess")
    end

    it "shows a time the locale can't misread" do
      # 01:00 rendered from hour/minute parts comes out as a bare "1:00" on a
      # 24-hour locale — inconsistent with "13:00" beside it, and one glance
      # from being read as the wrong half of the day.
      log_dose
      page.evaluate_async_script(<<~JS)
        (async () => {
          const [row] = await window.countaTest.rows();
          const data = await window.countaTest.decryptRow(row);
          data.history[0].time = "01:00";
          await window.countaTest.writeRow(row, data);
        })().then(arguments[0])
      JS
      reopen

      shown = find("#forecast-due .forecast-time").text
      expect(shown).not_to eq("1:00")
      expect(shown).to match(/\A(01:00|1:00\s?(AM|am|a\.m\.))\z/)
    end

    it "guesses from the clock, and says so, until it has seen a dose" do
      # An entry written before the field existed carries no time — the same
      # shape as every dose already in someone's history today.
      dose_on(browser_today - 1, 8)
      reopen

      expect(stored_times).to eq([ "" ])
      expect(find("#forecast-due .forecast-time")[:datetime]).to eq(rounded_now)
      expect(find("#forecast-due").text).to include("a guess from the time right now")
    end

    it "records no time for a backdated dose" do
      # A dose entered for last Tuesday was not taken at this moment, and
      # stamping the present on it would invent an observation that the
      # calendar export then sets real reminders from.
      page.execute_script(
        "document.getElementById('f-date').value = arguments[0];" \
        "document.getElementById('f-date').dispatchEvent(new Event('change', { bubbles: true }))",
        (browser_today - 5).iso8601
      )
      log_dose

      expect(stored_times).to eq([ "" ])
      expect(find("#forecast-due").text).to include("a guess from the time right now")

      # Positive control: the very next dose, entered as today, is observed —
      # so the absence above is the backdating, not the capture being broken.
      page.execute_script(
        "document.getElementById('f-date').value = arguments[0];" \
        "document.getElementById('f-date').dispatchEvent(new Event('change', { bubbles: true }))",
        browser_today.iso8601
      )
      log_dose
      expect(stored_times.reject(&:empty?).length).to eq(1)
      expect(find("#forecast-due").text).not_to include("a guess")
    end

    it "gives the calendar export the same time it shows on screen" do
      # #37's one-proxy rule, asserted across both surfaces rather than trusted.
      log_dose
      shown = find("#forecast-due .forecast-time")[:datetime]
      ics = page.evaluate_async_script("window.countaTest.icsPreview().then(arguments[0])")
      expect(ics).to match(/DTSTART:\d{8}T#{shown.delete(":")}00\r\n/)
    end
  end

  it "tells a screen reader the new due day when a dose is recorded" do
    # The forecast is not its own live region — it changes at exactly the
    # moment the dose-recorded announcement fires, and two regions speaking at
    # once is how one gets dropped. It rides in that one announcement instead.
    select WEGOVY_F, from: "f-product"
    save_pen(batch: "SR", expiry: "2027-06")
    log_dose

    live = find("#sr-live", visible: :all).text
    expect(live).to start_with("Dose recorded: 8 clicks.")
    expect(live).to include("Next dose due")
    expect(live).to include(find("#forecast-due .forecast-date").text)
  end

  # AGENTS.md §9.6 was learned from browser date arithmetic landing a day out
  # for a non-UTC user, and #37 names a DST case and a UTC+10 case as the
  # minimum bar. This machine runs Australia/Sydney, so both transitions are
  # real: DST ends 5 Apr 2026 (a 25-hour day) and starts 4 Oct 2026 (23 hours).
  describe "date arithmetic" do
    before do
      select WEGOVY_F, from: "f-product"
      save_pen(batch: "DST", expiry: "2027-06")
    end

    def add(iso, days)
      page.evaluate_script("window.countaTest.planAddDays(arguments[0], arguments[1])", iso, days)
    end

    it "lands on the right calendar day across both transitions" do
      expect(add("2026-04-01", 7)).to eq("2026-04-08") # through the 25-hour day
      expect(add("2026-10-01", 7)).to eq("2026-10-08") # through the 23-hour day
      expect(add("2026-10-03", 1)).to eq("2026-10-04") # onto the short day itself
      expect(add("2026-04-04", 1)).to eq("2026-04-05")
    end

    it "rolls over months and years" do
      # Plain correctness cover, and labelled as such: unlike the transitions
      # above there is no way to break these without breaking those too, so
      # they are regression value rather than a proof of any one mechanism.
      expect(add("2026-12-31", 7)).to eq("2027-01-07")
      expect(add("2026-02-27", 1)).to eq("2026-02-28")
      expect(add("2026-02-28", 1)).to eq("2026-03-01") # 2026 is not a leap year
    end

    it "never converts a date through an instant" do
      # §9.6's defect was an instant being reinterpreted in another zone. This
      # machine runs UTC+10/+11, so a date routed through toISOString from a
      # local evening reports a day early — the forecast avoids that class by
      # never holding an instant at all: the anchor is a stored date string,
      # addDays returns a date string, and the datetime attribute carries it
      # through verbatim. This pins the last link, which is the only one a
      # renderer could quietly break.
      dosed = browser_today - 1
      dose_on(dosed, 8)
      reopen

      due = find("#forecast-due .forecast-date")
      expect(due[:datetime]).to eq((dosed + 7).iso8601)
      # ...and the rendered text names the same day, so a locale format can't
      # drift a day from the machine-readable value beside it.
      expect(due.text).to include((dosed + 7).strftime("%-d"))
    end

    it "rounds a fractional cadence the same way the calendar export does" do
      # Twice weekly is 3.5 days; the export anchors with the same rounding, so
      # the two surfaces name the same day instead of drifting half a day apart.
      expect(add("2026-05-01", 3.5)).to eq("2026-05-05")
    end
  end
end
