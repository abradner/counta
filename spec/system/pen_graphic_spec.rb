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

  def piston_top
    # The piston has a 0.7s transition, so an immediate read catches it
    # mid-flight — measure the settled position, not the animation.
    page.execute_script("document.getElementById('piston-assembly').style.transition = 'none'")
    page.evaluate_script("document.getElementById('piston').getBoundingClientRect().top")
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

  # The fill gauge is a claim about how much medicine is left, so it needs to
  # be true. The piston is moved by a CSS transform in px on an SVG child,
  # which resolves in USER units — so it's independent of the viewBox, but
  # nothing pinned that until now.
  it "moves the piston across the cartridge in proportion to what's left" do
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    save_pen

    top = piston_top
    fill_in "f-dose", with: "2.4"
    find("#f-dose").native.send_keys(:tab)
    2.times { log_dose } # 148 of 296 clicks — half the pen
    halfway = piston_top

    2.times { log_dose } # empty
    expect(find("#stats").text).to include("0", "clicks left")
    bottom = piston_top

    travel = bottom - top
    expect(travel).to be > 0, "the piston never moved"
    # Half-used lands halfway: the gauge is proportional.
    expect(halfway - top).to be_within(travel * 0.05).of(travel / 2.0)

    # ...and an empty pen puts the piston at the bottom of the cartridge.
    # Proportionality alone isn't enough — a travel constant that's too small
    # is still perfectly proportional while showing medicine that isn't there.
    glass_bottom = page.evaluate_script(
      "document.getElementById('cartridge-glass').getBoundingClientRect().bottom"
    )
    piston_bottom = page.evaluate_script(
      "document.getElementById('piston').getBoundingClientRect().bottom"
    )
    expect(piston_bottom).to be_within(travel * 0.05).of(glass_bottom),
      "an empty pen doesn't show the piston at the bottom — the gauge implies " \
      "medicine that isn't there"
  end

  it "degrades to a sensible pen rather than black if a variable goes unset" do
    # The var() fallbacks are the second half of the fix: without them any
    # future path that fails to set a property paints the pen black again.
    page.execute_script("document.getElementById('pen-svg').style.cssText = ''")
    expect(fill_of("body-shell")).not_to eq("rgb(0, 0, 0)")
  end
end
