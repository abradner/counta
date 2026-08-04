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
    # Descriptive copy, and the disclaimer travels with the export.
    expect(ics).to include("Dose day — Wegovy: counter set to 8 clicks")
    expect(ics).to include("isn't medical advice")
    expect(ics).to include("Buy more Wegovy")

    # The schedule never touched the server: nothing about it is queryable.
    expect(Pen.sole.blob).not_to include("RRULE")
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
