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

  it "builds a deterministic client-side ICS schedule" do
    log_dose # 8 clicks → 36 full doses remain, schedule anchors on the dose date

    ics = page.evaluate_script("window.countaTest.icsPreview()")
    pen_id = Pen.sole.id

    expect(ics).to include("BEGIN:VCALENDAR")
    # Deterministic UIDs per pen so re-export replaces cleanly.
    expect(ics).to include("UID:counta-#{pen_id}-dose@counta.click")
    expect(ics).to include("UID:counta-#{pen_id}-refill@counta.click")
    # 288 clicks left at 8 clicks/dose = 36 doses, weekly.
    expect(ics).to include("RRULE:FREQ=DAILY;INTERVAL=7;COUNT=36")
    # Wegovy is a progress-style pen: the calendar entry must not imply the
    # window shows a number (docs/design-notes.md).
    expect(ics).to include("Dose day — Wegovy: dial 8 clicks (≈ 0.26 mg)")
    expect(ics).to include("the window shows no number")
    expect(ics).not_to include("counter will show")
    expect(ics).to include("isn't medical advice")
    expect(ics).to include("Buy more Wegovy")

    # The schedule never touched the server: nothing about it is queryable.
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

    ics = page.evaluate_script("window.countaTest.icsPreview()")
    expect(ics).to include("Dose day — Tresiba: dial 5 clicks — the counter will show 10 U")
    # The click count must never be presented as the number on the window.
    expect(ics).not_to include("counter will show 5")
    expect(ics).not_to include("counter set to")
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
