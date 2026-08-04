# The prototype behaviours, ported: setup → dose → warnings → history, with
# the blob staying opaque server-side and counter_style driving the readout
# copy (docs/design-notes.md "Dose-counter copy").
require "rails_helper"

RSpec.describe "Pen setup and dosing", type: :system do
  before do
    load Rails.root.join("db/seeds.rb")
    visit "/"
    add_virtual_authenticator
    sign_up_through_first_run
  end

  it "sets up a progress-style pen, logs a dose, and never sends plaintext" do
    # Wegovy is the first product alphabetically... select explicitly.
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    save_pen(batch: "LP7777", expiry: "2027-06")

    # Readout leads with clicks; progress windows show no number, and the copy
    # says so instead of implying the window shows the dose.
    expect(find("#readout-big").text).to eq("8 clicks")
    expect(find("#readout-sub").text)
      .to eq("≈ 0.26 mg · the window shows no number — your click count is the dose")
    # The pen graphic's counter window stays blank for progress pens.
    expect(find("#dose-value", visible: :all).text).to eq("")

    # Switcher + stats reflect the pen (chip is the pen switcher <select>).
    expect(find("#chip")).to have_text("Wegovy · 2.4 mg · 100%")
    expect(find("#stats").text).to include("296", "clicks left")

    log_dose
    expect(find("#history").text).to include("8 clicks")
    expect(find("#stats").text).to include("288")

    # Server holds ciphertext only — none of the sensitive fields appear.
    blob = Pen.sole.blob
    [ "Wegovy", "LP7777", "2027-06", "clicks", "history" ].each do |plaintext|
      expect(blob).not_to include(plaintext)
    end

    # Survives reload + unlock (blob round-trips through the server).
    visit "/"
    click_button "Unlock with passkey"
    expect(page).to have_css("#dose-card:not([hidden])", wait: 15)
    expect(find("#history").text).to include("8 clicks")
    expect(find("#chip")).to have_text("Wegovy · 2.4 mg · 97%")
  end

  it "uses numeric-counter copy for insulin pens" do
    select "Fiasp 100 U/mL (3 mL · 300 U)", from: "f-product"
    save_pen

    expect(find("#readout-big").text).to eq("2 clicks")
    expect(find("#readout-sub").text).to eq("counter will show 2")
    # Numeric windows really show the number, including on the graphic.
    expect(find("#dose-value", visible: :all).text).to eq("2")
  end

  it "warns when the pen will expire before the remaining doses fit" do
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    # Expires end of this month: 37 remaining doses at 7-day spacing can't fit.
    save_pen(expiry: Date.current.strftime("%Y-%m"))

    expect(find("#warnings").text).to include("before expiry")
  end

  it "flags an expired pen" do
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    save_pen(expiry: "2024-01")
    expect(find("#warnings").text).to include("expired 01/2024")
  end

  it "trashes a pen from the edit screen and returns to setup" do
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    save_pen
    expect(Pen.count).to eq(1)

    # Trash lives on the edit ("settings") screen, not the dose screen.
    expect(page).not_to have_button("Trash this pen")
    click_button "Edit this pen’s data"
    click_button "Trash this pen"
    within("#trash-dlg") { click_button "Trash pen" }
    expect(page).to have_css("#setup-card:not([hidden])", wait: 10)
    expect(Pen.count).to eq(0)
  end

  it "edits a pen without losing dose history" do
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    save_pen(batch: "OLD1")
    log_dose

    click_button "Edit this pen’s data"
    expect(page).to have_css("#setup-card:not([hidden])")
    fill_in "f-batch", with: "NEW2"
    click_button "Save pen"
    expect(page).to have_css("#dose-card:not([hidden])", wait: 10)
    expect(find("#history").text).to include("8 clicks")
  end
end
