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

  it "offers archiving on an empty pen, keeps its history, and sets a 2-year server-side TTL" do
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

    # Server-side TTL is exactly 2 years out — this is what PenPurgeJob acts on.
    expect(Pen.sole.purge_after).to eq(Date.current + 2.years)

    # Unarchive restores dose entry and clears the TTL.
    click_button "Unarchive this pen"
    expect(page).to have_css("#dose-entry", visible: :visible, wait: 10)
    expect(Pen.sole.purge_after).to be_nil
  end

  it "archives from the edit screen and lists archived pens separately in the switcher" do
    select "Fiasp 100 U/mL (3 mL · 300 U)", from: "f-product"
    save_pen

    click_button "Edit this pen’s data"
    click_button "Archive this pen"
    expect(page).to have_text("Archived", wait: 10)

    expect(find("#chip").find("optgroup[label='Archived']")).to have_text("Fiasp · archived")
    expect(Pen.sole.purge_after).to eq(Date.current + 2.years)
  end
end
