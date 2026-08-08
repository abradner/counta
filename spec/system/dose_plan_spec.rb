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
  def save_planned_wegovy(batch: "LP1234", started: nil)
    select WEGOVY, from: "f-product"
    select PRESET, from: "f-plan"
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

    it "reports an undeliverable step rather than quietly shrinking it" do
      # Reached by drift rather than at save: the plan is fine on this pen
      # today and the ladder later asks for more than the dial allows.
      save_planned_wegovy
      page.evaluate_async_script(<<~JS)
        (async () => {
          const [row] = await window.countaTest.rows();
          const data = await window.countaTest.decryptRow(row);
          data.plan.steps = [ { units: 9, doses: null, sourceLabel: null } ];
          await window.countaTest.writeRow(row, data);
        })().then(arguments[0])
      JS
      visit "/"
      click_button "Unlock with passkey"
      expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

      expect(find("#plan-dial-warn-text").text)
        .to eq("Your plan’s next dose is 9 mg. This pen’s dial reaches 2.4 mg.")
    end
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

    it "validates a step on amount and on the dial, and on nothing else" do
      err = ->(units, max, per) do
        js("window.countaTest.planStepError(arguments[0], arguments[1], arguments[2])", units, max, per)
      end
      per_click = 9.6 / 296
      expect(err.call(0, 74, per_click)).to eq("units")
      expect(err.call(-1, 74, per_click)).to eq("units")
      expect(err.call(2.4, 74, per_click)).to be_nil
      expect(err.call(4.8, 74, per_click)).to eq("dial")
      # A custom pen's dial limit is unknown, not unlimited: with nothing to
      # compare against, the dial check cannot fire.
      expect(err.call(4.8, nil, per_click)).to be_nil
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
