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

  # Regression: maxDialClicks was stored as Infinity, and JSON.stringify turns
  # Infinity into null, which read back through Math.min as 0 — clamping every
  # dose on a custom pen to 1 click after the first reload. A user dialling 30
  # clicks was shown, and would have recorded, 1.
  it "keeps a custom pen's dose intact across a reload" do
    select "Something else…", from: "f-product"
    fill_in "f-name", with: "Ozempic 1 mg"
    # An unlisted pen defaults to making no claim about its counter window.
    expect(find("#f-counter-style").value).to eq("progress")
    fill_in "f-cap-units", with: "8"
    fill_in "f-cap-unitname", with: "mg"
    fill_in "f-clicks", with: "300"
    save_pen(batch: "OZ1")

    find("#seg-clicks").click
    fill_in "f-dose", with: "30"
    find("#f-dose").native.send_keys(:tab)
    expect(find("#readout-big").text).to eq("30 clicks")

    visit "/"
    click_button "Unlock with passkey"
    expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

    # The dial must still reach 30 — before the fix it was pinned to 1.
    find("#seg-clicks").click
    fill_in "f-dose", with: "30"
    find("#f-dose").native.send_keys(:tab)
    expect(find("#readout-big").text).to eq("30 clicks")
  end

  # Regression: editing any field silently reset a custom capacity back to the
  # product preset, which rewrites the clicks-to-mg ratio for every future
  # dose on a pen that holds something else.
  it "preserves a custom capacity when only the batch is edited" do
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    select "Custom…", from: "f-capacity"
    fill_in "f-cap-units", with: "4.8"
    fill_in "f-clicks", with: "148"
    save_pen(batch: "HALF1")
    expect(find("#stats").text).to include("4.8")

    click_button "Edit this pen’s data"
    fill_in "f-batch", with: "HALF2"
    click_button "Save pen"
    expect(page).to have_css("#dose-card:not([hidden])", wait: 10)

    # Capacity must still be the half pen, not the 9.6 mg preset.
    expect(find("#stats").text).to include("4.8")
    expect(find("#stats").text).not_to include("9.6")
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
