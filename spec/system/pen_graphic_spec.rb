# Issue #17: the pen rendered as a black silhouette until a pen was saved.
#
# Two causes: the strict CSP blocks inline `style` attributes, which is where
# the default theme lived, and the port from assets/counta-pen.svg had dropped
# every var() fallback — so an unset custom property resolved to nothing and
# SVG fill fell back to its initial value, black.
require "rails_helper"

RSpec.describe "Pen graphic", type: :system do
  before do
    load Rails.root.join("db/seeds.rb")
    visit "/"
    add_virtual_authenticator
    sign_up_through_first_run
  end

  def fill_of(id)
    page.evaluate_script("getComputedStyle(document.getElementById('#{id}')).fill")
  end

  it "is themed on a brand-new account, before any pen exists" do
    expect(page).to have_css("#setup-card:not([hidden])")

    # The assertion that would have caught this the day the CSP landed.
    expect(fill_of("body-shell")).not_to eq("rgb(0, 0, 0)"),
      "the pen is rendering unthemed — check the CSP isn't dropping an inline style"
    expect(fill_of("label-bg")).not_to eq("rgb(0, 0, 0)")
  end

  it "restyles when a different product is chosen" do
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    wegovy = fill_of("body-shell")

    select "Fiasp 100 U/mL (3 mL · 300 U)", from: "f-product"
    fiasp = fill_of("body-shell")

    expect(fiasp).not_to eq(wegovy),
      "changing product didn't restyle the pen — the preview isn't repainting"
    expect(fiasp).not_to eq("rgb(0, 0, 0)")
  end

  it "keeps its theme after saving, and when editing an existing pen" do
    select "Fiasp 100 U/mL (3 mL · 300 U)", from: "f-product"
    saved_theme = fill_of("body-shell")
    save_pen

    expect(fill_of("body-shell")).to eq(saved_theme)

    click_button "Edit this pen’s data"
    expect(fill_of("body-shell")).to eq(saved_theme),
      "editing lost the pen's colours"
  end

  it "degrades to a sensible pen rather than black if a variable goes unset" do
    # The var() fallbacks are the second half of the fix: without them any
    # future path that fails to set a property paints the pen black again.
    page.execute_script("document.getElementById('pen-svg').style.cssText = ''")
    expect(fill_of("body-shell")).not_to eq("rgb(0, 0, 0)")
  end
end
