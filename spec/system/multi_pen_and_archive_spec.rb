require "rails_helper"

RSpec.describe "Multiple pens and archiving", type: :system do
  before do
    load Rails.root.join("db/seeds.rb")
    visit "/"
    add_virtual_authenticator
    sign_up_through_first_run
  end

  it "adds a second medication and switches between pens from the header" do
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    save_pen(batch: "WEG1")

    # The header chip is the switcher AND the way to add another pen.
    select "＋ Add a pen", from: "chip"
    expect(page).to have_css("#setup-card:not([hidden])", wait: 10)
    select "Fiasp 100 U/mL (3 mL · 300 U)", from: "f-product"
    save_pen(batch: "FIA1")

    expect(Pen.count).to eq(2)
    expect(find("#readout-sub").text).to eq("counter will show 2") # Fiasp is active

    # Switch back to the first pen; its own product copy returns.
    find("#chip").find(:option, text: /Wegovy/).select_option
    expect(find("#readout-sub").text)
      .to eq("≈ 0.26 mg · the window shows no number — your click count is the dose")
  end

  it "offers archiving on an empty pen, keeps its history, and stamps the archive server-side" do
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    save_pen

    # A pen with doses left offers no archive button...
    expect(page).not_to have_button("Archive this pen")

    # ...empty it (dial the max dose repeatedly) and the offer appears.
    fill_in "f-dose", with: "2.4"
    find("#f-dose").native.send_keys(:tab)
    4.times { log_dose }
    expect(find("#stats").text).to include("0", "clicks left")
    expect(page).to have_button("Archive this pen")

    click_button "Archive this pen"
    expect(page).to have_text("Archived", wait: 10)
    expect(page).to have_text("counta.click deletes the record automatically")

    # History and batch survive; dose entry is gone.
    expect(find("#history").text).to include("clicks")
    expect(page).to have_css("#dose-entry", visible: :hidden)

    # The server stamped the archive time; the deadline is derived from it.
    pen = Pen.sole
    expect(pen.archived_at).to be_within(1.minute).of(Time.current)
    expect(pen.purge_after).to be_within(1.minute).of(2.years.from_now)

    # Unarchive restores dose entry and clears the stamp.
    click_button "Unarchive this pen"
    expect(page).to have_css("#dose-entry", visible: :visible, wait: 10)
    expect(Pen.sole.archived_at).to be_nil
  end

  it "keeps archived pens out of the switcher and lists them in the account panel" do
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    save_pen(batch: "WEG1")
    select "＋ Add a pen", from: "chip"
    select "Fiasp 100 U/mL (3 mL · 300 U)", from: "f-product"
    save_pen(batch: "FIA1")

    click_button "Edit this pen’s data"
    click_button "Archive this pen"
    expect(page).to have_text("Archived", wait: 10)

    # Not a switchable option — only the disabled marker for what's on screen.
    expect(find("#chip")).to have_no_css("option:not([disabled])", text: "Fiasp")
    expect(find("#chip")).to have_css("option[disabled]", text: "Fiasp · archived")
    expect(find("#chip")).to have_css("option", text: /Wegovy/) # still switchable

    # Archived pens live in the account panel, and can be reopened from there.
    find("#account-btn").click
    expect(find("#archived-list")).to have_text("Fiasp")
    within("#archived-list") { click_button "Open" }
    expect(page).to have_text("counta.click deletes the record automatically", wait: 10)
  end

  it "archives from the edit screen" do
    select "Fiasp 100 U/mL (3 mL · 300 U)", from: "f-product"
    save_pen

    click_button "Edit this pen’s data"
    click_button "Archive this pen"
    expect(page).to have_text("Archived", wait: 10)

    expect(Pen.sole.archived_at).to be_within(1.minute).of(Time.current)
  end

  it "shows an archived pen's real retention window when reopened later" do
    select "Fiasp 100 U/mL (3 mL · 300 U)", from: "f-product"
    save_pen
    click_button "Edit this pen’s data"
    click_button "Archive this pen"
    expect(page).to have_text("Archived", wait: 10)

    # Age the archive: the copy must reflect when it was actually archived,
    # not when it was looked at.
    Pen.sole.update_columns(archived_at: Time.utc(2025, 3, 9, 12, 0))

    visit "/"
    click_button "Unlock with passkey"
    expect(page).to have_css("#app-screen:not([hidden])", wait: 15)
    find("#account-btn").click
    within("#archived-list") { click_button "Open" }

    expect(find("#archived-note")).to have_text("Archived 9 Mar 2025", wait: 10)
    expect(find("#archived-note")).to have_text("until 9 Mar 2027")
  end
end
