# Dose plans / titration ladders (issue #21).
#
# A plan is the user's transcription of a schedule they and their prescriber
# chose. counta stores it inside the pen's own encrypted blob, derives which
# step the next dose belongs to by COUNTING DOSES (never by the calendar, so a
# gap can never escalate anyone), and reports facts plus a citation — it never
# paraphrases clinical guidance and never edits the plan.
#
# The derivations in plan.js are pure integer/string arithmetic, so the edge
# cases are probed directly through the test hooks; everything the user can see
# is driven through the real UI.
require "rails_helper"

RSpec.describe "Dose plan", type: :system do
  WEGOVY = "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)".freeze
  PRESET = "Novo Nordisk published escalation (TGA product information, revised 22 Jun 2026)".freeze

  before do
    load Rails.root.join("db/seeds.rb")
    visit "/"
    add_virtual_authenticator
    sign_up_through_first_run
  end

  # The browser's own local calendar date. Rails' Date.current can be a day
  # off it (the app config runs UTC, this machine runs UTC+10), and every date
  # the app reasons about is the browser's — deriving fixtures from the wrong
  # one is the spec-side version of the bug AGENTS.md §9.6 records.
  def browser_today
    Date.parse(page.evaluate_script(<<~JS))
      (() => { const d = new Date();
        return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; })()
    JS
  end

  def stored_pen(index = 0)
    page.evaluate_async_script(<<~JS, index)
      window.countaTest.rows()
        .then(rows => window.countaTest.decryptRow(rows[arguments[0]]))
        .then(arguments[1]);
    JS
  end

  # A Wegovy pen carrying the published escalation. `started` backdates the
  # plan's start, which matters whenever a spec needs doses to fall INSIDE the
  # plan: a dose earlier than the start date is deliberately not a plan dose.
  # `at`/`taken` answer the mid-journey question the setup card asks: which
  # amount you're taking now, and how many you've already had at it.
  def save_planned_wegovy(batch: "LP1234", started: nil, at: nil, taken: 0)
    select WEGOVY, from: "f-product"
    select PRESET, from: "f-plan"
    if at
      select "I’m taking #{at} now", from: "f-plan-progress"
      fill_in "f-plan-prior", with: taken
    end
    if started
      page.execute_script(
        "document.getElementById('f-plan-start').value = arguments[0];" \
        "document.getElementById('f-plan-start').dispatchEvent(new Event('change', { bubbles: true }))",
        started.iso8601
      )
    end
    save_pen(batch: batch, expiry: "2027-06")
  end

  describe "transcribing the published escalation" do
    before { save_planned_wegovy }

    it "opens on the plan's first step with the dial already set" do
      # 0.25 mg on a 9.6 mg / 296-click pen is 8 clicks. The dial is prefilled
      # from the plan rather than from the product's first common dose, which
      # is the whole feature felt without a tap.
      expect(find("#readout-big")).to have_text("8 clicks")
      expect(find("#plan-line").text)
        .to eq("Weeks 1–4 · 0.25 mg · 4 more doses at this amount")
    end

    it "names the amount on the doses-left tile instead of implying a total" do
      # 296 clicks / 8 = 37 doses of medicine in the pen, but the plan only
      # has four at this amount, and counta never forecasts past a step
      # boundary (it cannot know what the next step's pen holds).
      tile = find("#stats .stat:nth-child(2)")
      expect(tile.find(".v").text).to eq("4")
      expect(tile.find(".k").text).to eq("doses at 0.25 mg")
    end

    it "shows the document the steps were transcribed from" do
      link = find("#plan-source a")
      expect(link.text).to eq("TGA product information, revised 22 Jun 2026")
      expect(link[:href]).to start_with("https://www.ebs.tga.gov.au/")
      expect(link[:rel]).to include("noopener")
    end

    it "advances a step only when the doses for this one have been recorded" do
      3.times { log_dose }
      expect(find("#plan-line").text)
        .to eq("Weeks 1–4 · 0.25 mg · 1 more dose at this amount After that your plan moves to 0.5 mg.")

      log_dose
      expect(find("#plan-line").text)
        .to eq("Weeks 5–8 · 0.5 mg · 4 more doses at this amount")
      # ...and the dial follows the plan onto the new step: 0.5 mg is 15 clicks.
      expect(find("#readout-big")).to have_text("15 clicks")
    end

    it "announces the dose that was recorded, not the one dialled next" do
      # The re-dial after a dose moves the dial onto the next step's amount.
      # Reading the shared dial value after that announced the wrong number to
      # anyone using a screen reader — "Dose recorded: 15 clicks" for an
      # 8-click dose — and they have no visual readout to contradict it.
      3.times { log_dose }
      log_dose # the fourth completes the step, so the dial moves 8 -> 15
      expect(find("#readout-big")).to have_text("15 clicks")
      expect(find("#sr-live", visible: :all).text).to start_with("Dose recorded: 8 clicks.")
    end

    it "walks the ladder across the whole pen, one event per step" do
      # This example used to assert COUNT=37 — one recurring event repeating
      # "dial 8 clicks" for every dose the pen holds at the size on the dial.
      # That number was a fiction the moment the pen carried a plan: it assumed
      # the user ignores their own ladder and stays at 0.25 mg forever. RFC 5545
      # cannot vary SUMMARY across occurrences of one RRULE, so the amount can
      # only change by splitting the series (#45).
      #
      # The half of the old intent that still stands, and is asserted below: the
      # export must NOT truncate to the current step. It reaches 1.7 mg.
      ics = page.evaluate_async_script("window.countaTest.icsPreview().then(arguments[0])")

      # 296 clicks, 9.6 mg. Each step costs what it costs on THIS pen, and the
      # pen funds four doses of the first three steps and one of the fourth
      # before the 28 clicks left can no longer pay for a 52-click dose.
      expect(ics).to include("dial 8 clicks (≈ 0.26 mg)", "RRULE:FREQ=DAILY;INTERVAL=7;COUNT=4")
      expect(ics).to include("dial 15 clicks (≈ 0.49 mg)")
      expect(ics).to include("dial 31 clicks (≈ 1.01 mg)")
      # The final step is a single dose, so it carries no RRULE at all — a
      # COUNT=1 series draws as a recurrence in some clients.
      expect(ics).to include("dial 52 clicks (≈ 1.69 mg)")
      expect(ics.scan(/RRULE/).length).to eq(3)

      # One live event per funded step, in order, a fortnight-free chain of
      # four-dose blocks: today, +28d, +56d, +84d.
      # DTEND is what separates a live event from a tombstone — a cancelled one
      # carries UID/SEQUENCE/DTSTAMP/DTSTART too, and a laxer regex here matched
      # the cancelled s4 as though the pen had funded a fifth step.
      starts = ics.scan(
        /UID:[^\n]*-dose-s(\d)@counta\.click\r\nSEQUENCE:\d+\r\nDTSTAMP:[^\r]+\r\nDTSTART:(\d{8})T\d{6}\r\nDTEND:/
      )
      expect(starts.map(&:first)).to eq(%w[0 1 2 3])
      expect(starts.map { |_, d| Date.parse(d) })
        .to eq([ 0, 28, 56, 84 ].map { |n| browser_today + n })

      # Nothing is cancelled, because this pen has never exported: there is no
      # event in anyone's calendar to retire. An earlier cut sent a tombstone
      # for every step the plan could name — including 2.4 mg, which this pen
      # never reaches — and clients materialise a placeholder for a UID they
      # have never seen, so three junk events landed on today's date.
      expect(ics).not_to include("STATUS:CANCELLED")

      # Two doses before the ladder stalls — 13 doses funded, so ordinal 11,
      # which is 77 days out. Asserted exactly: a `>` comparison here passed
      # for the old 245-day answer too, and would have proved nothing.
      refill = ics[/UID:[^\n]*-refill@counta\.click.*?DTSTART;VALUE=DATE:(\d{8})/m, 1]
      expect(Date.parse(refill)).to eq(browser_today + 77)
    end

    it "chains segments by the same interval the recurrence steps by" do
      # The fractional-cadence branch had no coverage at all, and it is the one
      # where the recurrence and the chaining are computed separately and can
      # disagree: the RRULE steps whole hours per occurrence, so a segment's
      # start has to be that same integer times the doses before it. Rounding
      # the whole span instead drifts — at freqDays 1.1, two doses are 52 h
      # apart by the rule but 53 h by the span, compounding down the ladder.
      # 3.5 days is the only fractional cadence the form offers and 84 h is
      # exact, so this pins the branch rather than reproducing that drift.
      click_button "Edit this pen’s data"
      select "Twice a week", from: "f-freq"
      save_pen(batch: "LP1234", expiry: "2027-06")
      expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

      ics = page.evaluate_async_script("window.countaTest.icsPreview().then(arguments[0])")
      expect(ics).to include("RRULE:FREQ=HOURLY;INTERVAL=84;COUNT=4")

      # Asserted as dates, not as an elapsed-seconds difference: these are
      # floating local times, and a DST transition inside the span moves the
      # wall clock without moving the schedule (AGENTS.md §9.6, §9.9). Four
      # doses at 84 h is 14 days, and the second segment starts there.
      starts = ics.scan(/-dose-s\d@counta\.click.*?DTSTART:(\d{8})T\d{6}\r\nDTEND:/m).flatten
      expect(starts.length).to be > 1
      expect(Date.parse(starts[1]) - Date.parse(starts[0])).to eq(14)
    end

    it "cancels the ladder's events when the plan is removed" do
      # The first export writes the step series, and records how many step slots
      # this pen has ever used.
      page.evaluate_async_script("window.countaTest.icsPreview().then(arguments[0])")
      # Only the four steps this pen can fund — not the fifth, which the ladder
      # never reaches and so was never written to a calendar.
      expect(stored_pen["calendarSlots"]).to eq(%w[dose-s0 dose-s1 dose-s2 dose-s3])

      # That record is the whole reason the field exists. Once the plan is gone
      # there is no ladder left to enumerate, so a stateless export could not
      # name the events it wrote last time — and the old series would go on
      # firing beside the new one: two live sets of dose reminders, at
      # different amounts, on the same days.
      page.evaluate_async_script(<<~JS)
        (async () => {
          const [row] = await window.countaTest.rows();
          const data = await window.countaTest.decryptRow(row);
          data.plan = null;
          await window.countaTest.writeRow(row, data);
        })().then(arguments[0])
      JS
      visit "/"
      click_button "Unlock with passkey"
      expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

      ics = page.evaluate_async_script("window.countaTest.icsPreview().then(arguments[0])")
      # The unplanned series is live again...
      expect(ics).to match(
        /UID:[^\n]*-dose@counta\.click\r\nSEQUENCE:\d+\r\nDTSTAMP:[^\r]+\r\nDTSTART:[^\r]+\r\nDTEND:/
      )
      # ...and every step slot the last export left live is retired, not just
      # the ones some current plan happens to still name.
      step_events = ics.scan(/UID:[^\n]*-dose-s(\d)@counta\.click.*?END:VEVENT/m)
      expect(step_events.map(&:first)).to eq(%w[0 1 2 3])
      ics.scan(/UID:[^\n]*-dose-s\d+@counta\.click.*?END:VEVENT/m)
        .each { |vevent| expect(vevent).to include("STATUS:CANCELLED") }

      # Cancelled once, and then never again: the slots dropped out of
      # calendarSlots when they stopped being live, so a re-export has nothing
      # left to retire. Re-sending a cancellation for a UID the calendar has
      # already dropped is what makes clients re-create the placeholder, so
      # "stops" is the property that matters here, not just "happens".
      again = page.evaluate_async_script("window.countaTest.icsPreview().then(arguments[0])")
      expect(again).not_to include("STATUS:CANCELLED")
      expect(again).not_to match(/-dose-s\d+@counta\.click/)
    end

    it "stores the plan inside the encrypted blob and nothing in plaintext" do
      plan = stored_pen["plan"]
      expect(plan["steps"].length).to eq(5)
      expect(plan["steps"].last).to include("units" => 2.4, "doses" => nil)
      expect(plan["source"]["verified_on"]).to eq("2026-06-22")

      # Nothing about the plan reaches a column. The server holds ciphertext
      # plus the archive marker, and that is the whole of it.
      columns = Pen.first.attributes.except("blob").to_s
      expect(columns).not_to include("plan", "0.25", "escalation")
    end
  end

  # Hardly anyone transcribing a published escalation is on week one — most
  # people find counta partway up the ramp, and the doses behind them were
  # often taken on a starter pen, on tablets, or on a pen counta never saw.
  # Those are plan history, not pen history, so they are carried as a count on
  # the plan rather than backdated into some pen's dose log.
  describe "joining a plan partway through" do
    it "costs someone who really is starting nothing at all" do
      # Negative control for everything below: the extra question defaults to
      # the beginning, the count input stays out of the way until it's needed,
      # and the saved plan carries no head start.
      select WEGOVY, from: "f-product"
      select PRESET, from: "f-plan"
      expect(page).to have_select("f-plan-progress", selected: "Just starting this plan")
      expect(page).to have_css("#plan-prior-wrap", visible: :hidden)

      save_pen(batch: "NEW1", expiry: "2027-06")
      expect(stored_pen["plan"]["priorDoses"]).to eq(0)
      expect(find("#plan-line").text).to eq("Weeks 1–4 · 0.25 mg · 4 more doses at this amount")
    end

    it "offers every step of the published ladder as a position" do
      select WEGOVY, from: "f-product"
      select PRESET, from: "f-plan"
      expect(page).to have_select("f-plan-progress", options: [
        "Just starting this plan",
        "I’m taking 0.25 mg now", "I’m taking 0.5 mg now", "I’m taking 1 mg now",
        "I’m taking 1.7 mg now", "I’m taking 2.4 mg now"
      ])
    end

    it "starts on the step the person says they are on" do
      # Two full steps behind (4 + 4) plus two doses at 1 mg = 10 doses in.
      save_planned_wegovy(at: "1 mg", taken: 2)

      expect(find("#plan-line").text).to eq("Weeks 9–12 · 1 mg · 2 more doses at this amount")
      # ...and the dial opens on 1 mg, which is 31 clicks on this pen — not the
      # 8 clicks of a ladder read from the beginning.
      expect(find("#readout-big")).to have_text("31 clicks")
      expect(find("#stats .stat:nth-child(2) .k").text).to eq("doses at 1 mg")
      expect(stored_pen["plan"]["priorDoses"]).to eq(10)
    end

    it "counts logged doses on top of the ones already taken" do
      save_planned_wegovy(at: "1 mg", taken: 2)
      2.times { log_dose }
      # 10 behind + 2 logged = 12, which is the end of the 1 mg step.
      expect(find("#plan-line").text).to eq("Weeks 13–16 · 1.7 mg · 4 more doses at this amount")
    end

    it "starts counting today rather than backdating onto a pen's own history" do
      # The dangerous case, and the only one where the default is load-bearing:
      # a pen that ALREADY has doses. Left to its usual rule the plan would
      # start at that pen's earliest dose, and those doses would then be
      # counted on top of the head start the person just stated — the same
      # doses twice, moving them up the ladder.
      save_planned_wegovy(batch: "HAD", started: browser_today - 60)
      page.evaluate_async_script(<<~JS, (browser_today - 50).iso8601, (browser_today - 40).iso8601, (browser_today - 30).iso8601)
        (async () => {
          for (const d of [ arguments[0], arguments[1], arguments[2] ]) {
            await window.countaTest.appendDoseTo(0, d, 8);
          }
        })().then(arguments[3])
      JS
      visit "/"
      click_button "Unlock with passkey"
      expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

      click_button "Edit this pen’s data"
      select PRESET, from: "f-plan" # re-transcribe, now saying where they are
      select "I’m taking 0.5 mg now", from: "f-plan-progress"
      fill_in "f-plan-prior", with: 1
      click_button "Save pen"
      expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

      expect(stored_pen["plan"]["startedOn"]).to eq(browser_today.iso8601)
      # Five doses in (4 + 1), not eight: the pen's three older doses belong to
      # what came before, and the head start already accounts for them.
      expect(find("#plan-line").text).to eq("Weeks 5–8 · 0.5 mg · 3 more doses at this amount")
    end

    it "carries the head start onto the next pen without counting it twice" do
      save_planned_wegovy(batch: "PENA", at: "1 mg", taken: 2)
      2.times { log_dose } # 12 doses in: the 1.7 mg step
      click_button "Edit this pen’s data"
      click_button "Archive this pen"
      expect(page).to have_css("#archived-note:not([hidden])", wait: 10)

      select "＋ Add a pen", from: "chip"
      select WEGOVY, from: "f-product"
      select "Continue “Novo Nordisk published escalation” from your other pen", from: "f-plan"
      save_pen(batch: "PENB", expiry: "2028-01")

      # Still 12. The head start belongs to the plan, so it is added once
      # however many pens carry a copy — added per pen it would read 22 and
      # jump this person two steps up their ladder.
      expect(find("#plan-line").text).to eq("Weeks 13–16 · 1.7 mg · 4 more doses at this amount")
      expect(stored_pen(1)["plan"]["priorDoses"]).to eq(10)
    end

    it "refuses more doses at an amount than the plan has at it" do
      select WEGOVY, from: "f-product"
      select PRESET, from: "f-plan"
      select "I’m taking 1 mg now", from: "f-plan-progress"
      fill_in "f-plan-prior", with: 9 # the 1 mg step is four doses long
      accept_alert(wait: 5) { click_button "Save pen" }
      expect(page).to have_css("#setup-card:not([hidden])")
    end

    it "treats a head start past the end of a finite ladder as finished" do
      save_planned_wegovy
      page.evaluate_async_script(<<~JS)
        (async () => {
          const [row] = await window.countaTest.rows();
          const data = await window.countaTest.decryptRow(row);
          data.plan = { ...data.plan, priorDoses: 5,
                        steps: [ { units: 0.25, doses: 1, sourceLabel: null } ] };
          await window.countaTest.writeRow(row, data);
        })().then(arguments[0])
      JS
      visit "/"
      click_button "Unlock with passkey"
      expect(page).to have_css("#dose-card:not([hidden])", wait: 15)
      expect(find("#plan-line").text).to eq("Step 1 of 1 · 0.25 mg · every step recorded")
    end

    it "says back where the answer lands, before it is saved" do
      # The whole risk in "how many have you had at this amount" is the reader
      # being a dose out either way. Restating it in the app's own words makes
      # that visible while it can still be corrected.
      select WEGOVY, from: "f-product"
      select PRESET, from: "f-plan"
      expect(page).to have_css("#plan-position", visible: :hidden)

      select "I’m taking 1 mg now", from: "f-plan-progress"
      fill_in "f-plan-prior", with: 3
      expect(find("#plan-position").text)
        .to eq("counta will start you at 1 mg · 1 more dose at this amount.")

      # The boundary answer converges: someone who has had all four at 1 mg
      # and someone who says they're now on 1.7 with none taken land in the
      # same place, so the ±1 reading can't send them a step apart.
      fill_in "f-plan-prior", with: 4
      first_reading = find("#plan-position").text
      select "I’m taking 1.7 mg now", from: "f-plan-progress"
      fill_in "f-plan-prior", with: 0
      expect(find("#plan-position").text).to eq(first_reading)
    end
  end

  # Negative control for every assertion above: a pen with no plan must render
  # no step line AND still render its readout, so a spec that broke the whole
  # dose screen can't read as "the plan line is correctly absent".
  it "leaves a pen with no plan exactly as it was" do
    select WEGOVY, from: "f-product"
    expect(page).to have_select("f-plan", selected: "No plan — same dose each time")
    save_pen(batch: "NP1", expiry: "2027-06")

    expect(page).to have_css("#plan-block", visible: :hidden)
    expect(find("#readout-big")).to have_text("8 clicks")
    expect(find("#stats .stat:nth-child(2) .k").text).to eq("doses left")
    expect(stored_pen["plan"]).to be_nil
  end

  it "defaults a new pen's plan start to today rather than the last pen's" do
    # The date input survives the switch to another pen, and the form only
    # fills a blank one — so a second pen's plan quietly inherited the first
    # pen's start date, which would put its ladder on the wrong step.
    select WEGOVY, from: "f-product"
    select PRESET, from: "f-plan"
    page.execute_script(
      "document.getElementById('f-plan-start').value = '2026-01-15';" \
      "document.getElementById('f-plan-start').dispatchEvent(new Event('change', { bubbles: true }))"
    )
    save_pen(batch: "PENA", expiry: "2027-06")
    expect(stored_pen["plan"]["startedOn"]).to eq("2026-01-15")

    select "＋ Add a pen", from: "chip"
    select WEGOVY, from: "f-product"
    select PRESET, from: "f-plan"
    expect(find("#f-plan-start").value).to eq(browser_today.iso8601)
  end

  # The defect shape that issue #1 hit and issue #18 exists to remove:
  # savePenForm rebuilds the entire blob on every save, so a field it forgets
  # to carry forward is silently deleted by an edit that had nothing to do
  # with it. calendarUid/calendarSequence (#14) sit beside plan in that list.
  it "keeps the plan through an edit that only fixes the batch number" do
    save_planned_wegovy(batch: "TYPO")
    click_button "Edit this pen’s data"
    fill_in "f-batch", with: "LP9999"
    click_button "Save pen"
    expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

    data = stored_pen
    expect(data["batch"]).to eq("LP9999")
    expect(data["plan"]).not_to be_nil
    expect(data["plan"]["steps"].length).to eq(5)
    expect(find("#plan-line").text).to include("Weeks 1–4")
  end

  # The central promise of #21: a plan belongs to the person and their
  # medicine, not to one pen. A Wegovy pen holds four doses and a step is four
  # doses, so every step change is also a pen change.
  it "carries the plan and its dose count onto the next pen" do
    save_planned_wegovy(batch: "PENA")
    4.times { log_dose }
    # Four doses is a completed step, not an empty pen (296 clicks holds 37 at
    # this amount), so archiving is reached from the pen's settings.
    click_button "Edit this pen’s data"
    click_button "Archive this pen"
    expect(page).to have_css("#archived-note:not([hidden])", wait: 10)

    select "＋ Add a pen", from: "chip"
    select WEGOVY, from: "f-product"
    # A different strength of the same product: half the medicine over the
    # same dial, so every amount costs twice the clicks. The plan is stored in
    # mg precisely so it survives this.
    use_custom_capacity(4.8)
    select "Continue “Novo Nordisk published escalation” from your other pen", from: "f-plan"
    save_pen(batch: "PENB", expiry: "2028-01")

    # Step 2, because four doses were recorded under this plan on the pen that
    # is now archived — the count crosses pens by shared plan id.
    expect(find("#plan-line").text)
      .to eq("Weeks 5–8 · 0.5 mg · 4 more doses at this amount")
    # ...and 0.5 mg converts through THIS pen's ratio: 4.8 mg / 296 clicks
    # means 31 clicks, not the 15 the first pen needed.
    expect(find("#readout-big")).to have_text("31 clicks")

    plans = [ stored_pen(0)["plan"], stored_pen(1)["plan"] ]
    expect(plans.map { |p| p["id"] }.uniq.length).to eq(1)
  end

  # "Something else…" is the absence of a medicine, not a medicine: every
  # unlisted pen shares the productKey "custom", so donor matching on it would
  # have offered an unlisted insulin pen the mg ladder from an unlisted GLP-1.
  it "never offers one unlisted pen's plan to another" do
    select "Something else…", from: "f-product"
    fill_in "f-name", with: "Mystery A"
    use_custom_capacity(10)
    fill_in "f-clicks", with: "100"
    save_pen(batch: "CA", expiry: "2027-06")

    # A plan can't be created on an unlisted pen through the UI (no published
    # schedule to transcribe), so put one there the way another device would.
    page.evaluate_async_script(<<~JS)
      (async () => {
        const [row] = await window.countaTest.rows();
        const data = await window.countaTest.decryptRow(row);
        data.plan = { id: "custom-plan", rev: 1, label: "Hand-written ladder",
                      startedOn: "2026-01-01", source: null,
                      steps: [ { units: 1, doses: 4, sourceLabel: null } ] };
        await window.countaTest.writeRow(row, data);
      })().then(arguments[0])
    JS
    visit "/"
    click_button "Unlock with passkey"
    expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

    select "＋ Add a pen", from: "chip"
    select "Something else…", from: "f-product"
    # No published schedule, no plan of its own, and nothing it may inherit —
    # so the plan section isn't offered at all.
    expect(page).to have_css("#plan-wrap", visible: :hidden)
  end

  it "offers the plan the person is actually on, not the highest revision" do
    # `rev` counts edits within one plan, so it says nothing across plans. A
    # plain max-rev donor would hand a new pen a long-abandoned ladder that had
    # simply been edited more often than the current one.
    save_planned_wegovy(batch: "OLD", started: browser_today - 300)
    select "＋ Add a pen", from: "chip"
    save_planned_wegovy(batch: "NEW", started: browser_today - 10)

    page.evaluate_async_script(<<~JS, (browser_today - 3).iso8601)
      (async () => {
        const stale = await window.countaTest.decryptRowAt(0);
        stale.plan = { ...stale.plan, rev: 99, label: "Abandoned ladder" };
        await window.countaTest.writeRowAt(0, stale);
        await window.countaTest.appendDoseTo(1, arguments[0], 8);
      })().then(arguments[1])
    JS
    visit "/"
    click_button "Unlock with passkey"
    expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

    select "＋ Add a pen", from: "chip"
    select WEGOVY, from: "f-product"
    # The pen with a recent dose wins, though its plan is on rev 1 and the
    # abandoned one is on rev 99.
    expect(page).to have_select("f-plan", with_options:
      [ "Continue “Novo Nordisk published escalation” from your other pen" ])
    expect(page).not_to have_select("f-plan", with_options: [ "Continue “Abandoned ladder” from your other pen" ])
  end

  it "does not let another medicine's doses advance the ladder" do
    save_planned_wegovy(batch: "WGV")
    select "＋ Add a pen", from: "chip"
    select "Tresiba 200 U/mL (3 mL · 600 U)", from: "f-product"
    save_pen(batch: "TR9", expiry: "2028-01")

    # Two independent things keep a dose out of this ladder's count, and each
    # is exercised on its own here — otherwise reverting either would leave
    # the other covering it and the spec would prove nothing (AGENTS.md §9.10).
    #
    #   (a) four doses on the INSULIN pen, dated today so the plan's start
    #       date cannot be what excludes them: only the plan-id scoping can.
    #   (b) one dose on the WEGOVY pen itself, backdated to before the plan
    #       started: only the start-date filter can exclude that one.
    page.evaluate_async_script(<<~JS, browser_today.iso8601, (browser_today - 40).iso8601)
      (async () => {
        for (let i = 0; i < 4; i++) await window.countaTest.appendDoseTo(1, arguments[0], 10);
        await window.countaTest.appendDoseTo(0, arguments[1], 8);
      })().then(arguments[2])
    JS

    # Those writes went straight to the server, so this tab's decrypted copy
    # is stale — reload, or the derivation under test never sees the doses and
    # the assertion below would hold no matter what the scoping did
    # (AGENTS.md §9.10, "the spec never reaches the mechanism").
    visit "/"
    click_button "Unlock with passkey"
    expect(page).to have_css("#dose-card:not([hidden])", wait: 15)
    # The Wegovy pen was created first, so it is the one the app reopens on.
    expect(page).to have_select("chip", selected: "Wegovy · 2.4 mg · 97%")
    # Five doses exist across the account; none of them belong to this plan,
    # so it is still on its first step with all four doses ahead of it.
    expect(find("#plan-line").text).to eq("Weeks 1–4 · 0.25 mg · 4 more doses at this amount")

    # And the same scoping has to reach the gap notice. The Wegovy dose above
    # is 40 days old, which is five missed weeks by the calendar — but it
    # predates the plan, so this plan has not been missed at all. Raising a
    # missed-dose warning against a plan that started today would be a false
    # alarm about someone's medication.
    expect(page).to have_css("#plan-gap", visible: :hidden)
  end

  describe "a pen that cannot dial the plan" do
    it "refuses to save a plan whose next step is past this pen's dial" do
      select WEGOVY, from: "f-product"
      # 0.5 mg spread over the same 296 clicks: 0.25 mg then needs 148 clicks,
      # and the pen's dial stops at 74.
      use_custom_capacity(0.5)
      select PRESET, from: "f-plan"
      accept_alert(wait: 5) do
        click_button "Save pen"
      end
      expect(page).to have_css("#setup-card:not([hidden])")
    end

    it "refuses a step that rounds to less than one click on this pen" do
      select WEGOVY, from: "f-product"
      # A mistyped capacity — 300 mg where the pen holds 9.6 — makes one click
      # worth about a milligram, so the ladder's 0.25 mg first step rounds to
      # nothing. The mirror of the too-big check, and just as undialable.
      use_custom_capacity(300)
      select PRESET, from: "f-plan"
      accept_alert(wait: 5) { click_button "Save pen" }
      expect(page).to have_css("#setup-card:not([hidden])")
    end

    # One fixture, three defects. A plan asking for far more than this pen can
    # dial used to make the pen's own numbers lie: the running-low warning
    # fired on a brand-new pen, and the calendar export refused outright.
    it "reports the undeliverable step without misreporting the pen" do
      save_planned_wegovy
      page.evaluate_async_script(<<~JS)
        (async () => {
          const [row] = await window.countaTest.rows();
          const data = await window.countaTest.decryptRow(row);
          data.plan.steps = [ { units: 20, doses: null, sourceLabel: null } ];
          await window.countaTest.writeRow(row, data);
        })().then(arguments[0])
      JS
      visit "/"
      click_button "Unlock with passkey"
      expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

      # Said plainly, and the plan is left exactly as the user wrote it.
      expect(find("#plan-dial-warn-text").text)
        .to eq("Your plan’s next dose is 20 mg. This pen’s dial reaches 2.4 mg.")
      # The plan has nothing this pen can deliver at this step...
      expect(find("#stats .stat:nth-child(2) .v").text).to eq("0")
      # ...but the PEN is full, and its own warnings must say so. Deriving
      # them from the plan's fictional step size reported "not enough left in
      # this pen for a full dose" on 296 untouched clicks.
      expect(find("#stats .stat:nth-child(3) .v").text).to eq("296")
      expect(page).to have_css("#warnings")
      expect(find("#warnings").text).to be_empty

      # Positive control for that absence: the warning is not simply broken —
      # it appears the moment the pen really is down to its last dialled dose.
      # (74 clicks is the dial max, so three of them leave exactly one.)
      page.evaluate_async_script(<<~JS)
        (async () => {
          for (let i = 0; i < 3; i++) await window.countaTest.appendDoseTo(0, "2020-01-01", 74);
        })().then(arguments[0])
      JS
      visit "/"
      click_button "Unlock with passkey"
      expect(page).to have_css("#dose-card:not([hidden])", wait: 15)
      expect(find("#warnings").text).to include("last full dose")
    end

    it "still exports a calendar for a pen the plan has outgrown" do
      save_planned_wegovy
      page.evaluate_async_script(<<~JS)
        (async () => {
          const [row] = await window.countaTest.rows();
          const data = await window.countaTest.decryptRow(row);
          data.plan.steps = [ { units: 20, doses: null, sourceLabel: null } ];
          await window.countaTest.writeRow(row, data);
        })().then(arguments[0])
      JS
      visit "/"
      click_button "Unlock with passkey"
      expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

      # The export counts what the pen holds at the size actually dialled — it
      # used to read the plan's at-this-step number and conclude a full pen had
      # nothing left to schedule, which was simply untrue. The ladder walk
      # (#45) can reintroduce exactly that: a 20 mg step costs 617 clicks on a
      # 296-click pen, so it funds no doses and the walk returns nothing. This
      # is the regression test for the fallback that catches it.
      ics = page.evaluate_async_script("window.countaTest.icsPreview().then(arguments[0])")
      expect(ics).to include("COUNT=4")

      # On the legacy single-event UID, and LIVE — it has a DTEND rather than a
      # tombstone. The ladder path emits -dose-s{n} and cancels this one; the
      # fallback does the opposite. What must never happen is both, because a
      # file naming one UID live and cancelled loses the live copy in most
      # clients, silently deleting the user's whole schedule.
      expect(ics).to match(
        /UID:[^\n]*-dose@counta\.click\r\nSEQUENCE:\d+\r\nDTSTAMP:[^\r]+\r\nDTSTART:[^\r]+\r\nDTEND:/
      )
      # No step event at all, live or cancelled: the ladder never laid one out
      # on this pen, so there is nothing in a calendar to retire.
      expect(ics).not_to match(/-dose-s\d+@counta\.click/)
      expect(ics).not_to include("STATUS:CANCELLED")
    end
  end

  # A plan with no steps is not "no plan": it can never say what the next dose
  # is. Unreachable from this client's own form, but a 409 merge adopts
  # whatever another device stored, so the dose screen has to survive it.
  it "survives a plan with no steps in it" do
    save_planned_wegovy
    page.evaluate_async_script(<<~JS)
      (async () => {
        const [row] = await window.countaTest.rows();
        const data = await window.countaTest.decryptRow(row);
        data.plan = { ...data.plan, steps: [] };
        await window.countaTest.writeRow(row, data);
      })().then(arguments[0])
    JS
    visit "/"
    click_button "Unlock with passkey"

    # The pen opens, rather than the whole screen throwing on a missing step.
    expect(page).to have_css("#dose-card:not([hidden])", wait: 15)
    expect(find("#readout-big")).to have_text("8 clicks")
    expect(page).to have_css("#plan-block", visible: :hidden)

    # And re-saving refuses it rather than writing it back as if it were fine.
    click_button "Edit this pen’s data"
    accept_alert(wait: 5) { click_button "Save pen" }
    expect(page).to have_css("#setup-card:not([hidden])")
  end

  describe "a gap in dosing" do
    # The label response counta gives is facts plus a link, never a paraphrase:
    # the Australian product information allows five days to catch up and says
    # re-initiation "should be considered"; the US label says two days and
    # "reinitiate". One sentence cannot be true of both, so counta writes
    # neither and cites the document it is calibrated to.
    it "states the gap, cites the document, and offers to open the plan" do
      # The plan has been running two months; the dose below falls inside it.
      # Started today, that dose would predate the plan and correctly count
      # for nothing — which is the scoping the isolation spec above pins.
      save_planned_wegovy(started: browser_today - 60)
      last = browser_today - 23
      page.evaluate_async_script(<<~JS, last.iso8601)
        window.countaTest.appendDoseTo(0, arguments[0], 8).then(arguments[1]);
      JS
      visit "/"
      click_button "Unlock with passkey"
      expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

      expect(page).to have_css("#plan-gap:not([hidden])")
      # Assert the machine-readable date, never the locale-formatted text
      # (AGENTS.md §9.9) — and the day count, which is the number a UTC-shifted
      # calculation would get wrong for this UTC+10 machine (§9.6).
      expect(find("#plan-gap time")[:datetime]).to eq(last.iso8601)
      expect(find("#plan-gap-text").text)
        .to eq("Your last recorded dose was #{find('#plan-gap time').text} — 23 days ago. " \
               "Your plan expects one every 7 days.")
      expect(find("#plan-gap-source")[:href]).to start_with("https://www.ebs.tga.gov.au/")

      click_button "Edit your plan"
      expect(page).to have_css("#setup-card:not([hidden])")
    end

    it "says nothing when the next dose is merely due" do
      # Positive control's partner: a seven-day gap is a dose due today, not a
      # missed one, and a guard that fires here would be tuned away later.
      save_planned_wegovy(started: browser_today - 60)
      page.evaluate_async_script(<<~JS, (browser_today - 7).iso8601)
        window.countaTest.appendDoseTo(0, arguments[0], 8).then(arguments[1]);
      JS
      visit "/"
      click_button "Unlock with passkey"
      expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

      expect(page).to have_css("#plan-gap", visible: :hidden)
      expect(page).to have_css("#plan-line") # the screen did render
    end
  end

  # plan.js's pure derivations. Integer and string arithmetic with no DOM, so
  # the edges are exact here and would cost a browser round trip each in the UI.
  describe "derivations" do
    before { save_planned_wegovy }

    def js(expr, *args)
      page.evaluate_script("(function(){ return #{expr}; })(...arguments)", *args)
    end

    it "maps dose ordinals onto steps, including the open-ended tail" do
      finite = [ { "units" => 1, "doses" => 2 }, { "units" => 2, "doses" => 3 } ]
      expect(js("window.countaTest.planStepIndex(arguments[0], 0)", finite)).to eq(0)
      expect(js("window.countaTest.planStepIndex(arguments[0], 1)", finite)).to eq(0)
      expect(js("window.countaTest.planStepIndex(arguments[0], 2)", finite)).to eq(1)
      expect(js("window.countaTest.planStepIndex(arguments[0], 4)", finite)).to eq(1)
      # Past the end of a finite ladder: hold at the last step, never throw.
      expect(js("window.countaTest.planStepIndex(arguments[0], 99)", finite)).to eq(1)

      # An open-ended step absorbs every later dose — both a maintenance dose
      # and a deliberate hold look like this.
      open = [ { "units" => 1, "doses" => 2 }, { "units" => 2, "doses" => nil },
               { "units" => 3, "doses" => 4 } ]
      expect(js("window.countaTest.planStepIndex(arguments[0], 2)", open)).to eq(1)
      expect(js("window.countaTest.planStepIndex(arguments[0], 500)", open)).to eq(1)
    end

    it "counts whole days across both daylight-saving transitions" do
      # This machine runs Australia/Sydney: DST ends 5 Apr 2026 (a 25-hour day)
      # and starts 4 Oct 2026 (a 23-hour day). Rounding is what makes the day
      # count survive both; a floor would turn the October week into six days.
      expect(js('window.countaTest.planDaysBetween("2026-04-01", "2026-04-08")')).to eq(7)
      expect(js('window.countaTest.planDaysBetween("2026-10-01", "2026-10-08")')).to eq(7)
      expect(js('window.countaTest.planDaysBetween("2026-09-28", "2026-10-26")')).to eq(28)
      expect(js('window.countaTest.planDaysBetween("2026-03-01", "2026-03-01")')).to eq(0)
    end

    it "counts missed doses from the trailing gap, not from the clock" do
      probe = ->(last, today, freq) do
        js("window.countaTest.planMissedDoses(arguments[0], arguments[1], arguments[2])", last, today, freq)
      end
      expect(probe.call("2026-03-01", "2026-03-08", 7)).to eq(0)  # due today
      expect(probe.call("2026-03-01", "2026-03-09", 7)).to eq(0)  # a day late
      expect(probe.call("2026-03-01", "2026-03-15", 7)).to eq(1)
      expect(probe.call("2026-03-01", "2026-03-22", 7)).to eq(2)
      expect(probe.call("2026-03-01", "2026-03-12", 3.5)).to eq(2) # fractional cadence
      expect(probe.call(nil, "2026-03-22", 7)).to eq(0)            # no doses yet
      # Crossing October's short week must not invent a missed dose.
      expect(probe.call("2026-10-01", "2026-10-08", 7)).to eq(0)
    end

    it "stops counting once a finite ladder has been fully dosed" do
      # stepIndexFor deliberately holds at the last step rather than running
      # off the end, so nothing about the step index says "finished". Without
      # the completion flag the count kept going until the pen emptied, and
      # the tile contradicted the plan line. The shipped preset ends
      # open-ended, so this only bites a hand-written ladder (issue #44).
      finite = [ { "units" => 1, "doses" => 2 }, { "units" => 2, "doses" => 2 } ]
      probe = ->(taken) do
        js("window.countaTest.planDosesLeftAt(arguments[0], arguments[1], 500, 1)", finite, taken)
      end
      expect(probe.call(0)).to eq("left" => 2, "complete" => false)
      expect(probe.call(3)).to eq("left" => 1, "complete" => false)
      expect(probe.call(4)).to eq("left" => 0, "complete" => true)
      expect(probe.call(9)).to eq("left" => 0, "complete" => true)

      # An open-ended tail is never "complete", and is bounded by the pen.
      open_ended = [ { "units" => 1, "doses" => 2 }, { "units" => 2, "doses" => nil } ]
      expect(js("window.countaTest.planDosesLeftAt(arguments[0], 5, 9, 1)", open_ended))
        .to eq("left" => 4, "complete" => false) # 9 clicks / 2 per dose
    end

    it "says a finished ladder is finished rather than counting zero of it" do
      # The count above is held to zero by the step's own remaining-doses
      # figure, so the completion flag is not what produces it — this is the
      # assertion that makes the flag load-bearing, and the copy is the reason
      # it exists: "0 more doses at this amount" reads like a defect.
      page.evaluate_async_script(<<~JS)
        (async () => {
          const [row] = await window.countaTest.rows();
          const data = await window.countaTest.decryptRow(row);
          data.plan = { ...data.plan,
            steps: [ { units: 0.25, doses: 1, sourceLabel: null } ] };
          await window.countaTest.writeRow(row, data);
        })().then(arguments[0])
      JS
      visit "/"
      click_button "Unlock with passkey"
      expect(page).to have_css("#dose-card:not([hidden])", wait: 15)
      expect(find("#plan-line").text).to eq("Step 1 of 1 · 0.25 mg · 1 more dose at this amount")

      log_dose
      expect(find("#plan-line").text).to eq("Step 1 of 1 · 0.25 mg · every step recorded")
    end

    it "offers no position beyond an open-ended step" do
      # The shipped ladder's open-ended step is its last, so the filter is a
      # no-op there and the UI spec above cannot exercise it — a hand-written
      # ladder (issue #44) can put one in the middle, and nothing after it is
      # a position anyone can reach.
      trailing = [ { "units" => 1, "doses" => 2 }, { "units" => 2, "doses" => nil } ]
      middle = [ { "units" => 1, "doses" => 2 }, { "units" => 2, "doses" => nil },
                 { "units" => 3, "doses" => 4 } ]
      expect(js("window.countaTest.planReachableSteps(arguments[0])", trailing)).to eq(2)
      expect(js("window.countaTest.planReachableSteps(arguments[0])", middle)).to eq(2)
    end

    it "converges on the same head start from either side of a boundary" do
      # "I've had all four at 1 mg" and "I'm on 1.7 with none yet" are the same
      # position stated two ways, and the arithmetic has to agree — otherwise
      # the ±1 reading of the question lands people a dose apart.
      steps = [ { "units" => 0.25, "doses" => 4 }, { "units" => 0.5, "doses" => 4 },
                { "units" => 1, "doses" => 4 }, { "units" => 1.7, "doses" => 4 } ]
      prior = ->(i, n) { js("window.countaTest.planPriorDosesFor(arguments[0], arguments[1], arguments[2])", steps, i, n) }
      expect(prior.call(2, 4)).to eq(12)
      expect(prior.call(3, 0)).to eq(12)
      expect(prior.call(0, 0)).to eq(0)
      expect(prior.call(2, 2)).to eq(10)
    end

    it "validates a step on amount and on the dial, and on nothing else" do
      err = ->(units, max, per) do
        js("window.countaTest.planStepError(arguments[0], arguments[1], arguments[2])", units, max, per)
      end
      per_click = 9.6 / 296
      expect(err.call(0, 74, per_click)).to eq("units")
      expect(err.call(-1, 74, per_click)).to eq("units")
      expect(err.call(2.4, 74, per_click)).to be_nil
      expect(err.call(4.8, 74, per_click)).to eq("dial")
      # Below one click is as undialable as above the dial's limit, and it is
      # what a mistyped capacity produces.
      expect(err.call(0.25, 74, 1.0)).to eq("tiny")
      # A custom pen's dial limit is unknown, not unlimited: with nothing to
      # compare against, the dial check cannot fire — but the tiny check,
      # which needs no limit, still does.
      expect(err.call(4.8, nil, per_click)).to be_nil
      expect(err.call(0.25, nil, 1.0)).to eq("tiny")
    end
  end

  # Issue #14 established that the 409 handler needs a per-field policy for
  # anything that isn't append-only; the handler's comment named plan.rev as
  # the next arrival. Both halves of that policy are exercised here.
  describe "a stale tab and a plan edited elsewhere" do
    before { save_planned_wegovy }

    it "adopts the other device's plan when this write never meant to touch it" do
      page.evaluate_async_script(<<~JS)
        (async () => {
          const [row] = await window.countaTest.rows();
          const data = await window.countaTest.decryptRow(row);
          data.plan = { ...data.plan, rev: 7, label: "Edited elsewhere",
                        steps: [ { units: 1.7, doses: null, sourceLabel: null } ] };
          await window.countaTest.writeRow(row, data);
        })().then(arguments[0])
      JS

      # Logging a dose says nothing about the plan, so the retry must not push
      # this tab's stale copy over the edit.
      log_dose
      expect(stored_pen["plan"]).to include("rev" => 7, "label" => "Edited elsewhere")
    end

    it "keeps the newer revision when both devices meant to set the plan" do
      page.evaluate_async_script(<<~JS)
        (async () => {
          const [row] = await window.countaTest.rows();
          const data = await window.countaTest.decryptRow(row);
          data.plan = { ...data.plan, rev: 9, label: "Newer elsewhere" };
          await window.countaTest.writeRow(row, data);
        })().then(arguments[0])
      JS

      # This tab re-saves the pen (a plan-intent write) holding rev 1.
      click_button "Edit this pen’s data"
      fill_in "f-batch", with: "LATER"
      click_button "Save pen"
      expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

      data = stored_pen
      expect(data["batch"]).to eq("LATER")          # this tab's edit landed
      expect(data["plan"]["rev"]).to eq(9)          # ...but theirs is the newer plan
      expect(data["plan"]["label"]).to eq("Newer elsewhere")
    end
  end
end
