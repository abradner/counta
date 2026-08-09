# Captures the screenshots used in README.md and docs/ui-tour.md, by
# driving the real app rather than mocking anything — so the images can't
# drift from what the app actually renders.
#
#   SCREENSHOTS=1 mise exec -- bundle exec rspec spec/system/screenshots_spec.rb
#
# Skipped by default: it's a documentation build step, not a check.
require "rails_helper"

RSpec.describe "Screenshots", type: :system, if: ENV["SCREENSHOTS"] == "1" do
  SHOT_DIR = Rails.root.join("docs/screenshots")

  def shot(name, width: 460, height: 900)
    page.driver.resize_window_to(page.driver.current_window_handle, width, height)
    sleep 0.35
    FileUtils.mkdir_p(SHOT_DIR)
    page.save_screenshot(SHOT_DIR.join("#{name}.png"))
  end

  before { load Rails.root.join("db/seeds.rb") }

  it "captures the full first-run and daily-use journey" do
    visit "/"
    shot("01-landing")

    add_virtual_authenticator
    click_button "Create account"
    expect(page).to have_css("#disclaimer-dlg[open]")
    shot("02-disclaimer")

    within("#disclaimer-dlg") { click_button "I understand — continue" }
    expect(page).to have_css("#kit-dlg[open]", wait: 15)
    shot("03-recovery-kit", height: 760)
    find("#kit-words-toggle").click
    shot("04-recovery-kit-words", height: 1000)
    check "kit-saved-check"
    click_button "Continue"

    expect(page).to have_css("#setup-card", wait: 15)
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    shot("05-pen-setup", height: 1300)

    # Transcribe the published escalation, so the tour shows the dose plan on
    # both the setup card and the dose screen (#21).
    select "Novo Nordisk published escalation (TGA product information, revised 22 Jun 2026)",
           from: "f-plan"
    shot("05b-dose-plan", height: 1460)

    # Most people find counta partway up the ramp, so the tour shows that too.
    select "I’m taking 1 mg now", from: "f-plan-progress"
    fill_in "f-plan-prior", with: 2
    shot("05c-dose-plan-partway", height: 1460)
    select "Just starting this plan", from: "f-plan-progress"

    save_pen(batch: "LP1234", expiry: "2027-06")
    shot("06-dose-screen", height: 1000)

    click_button "Dose now"
    expect(page).to have_css("#confirm-dlg[open]")
    shot("07-confirm-dose")
    within("#confirm-dlg") { click_button "Yes, I dosed" }
    expect(page).to have_css("#history li strong", wait: 10)

    click_button "Add dose reminders to calendar"
    expect(page).to have_css("#ics-dlg[open]")
    shot("08-calendar-export")
    within("#ics-dlg") { click_button "Cancel" }

    # A second medication, to show the switcher.
    select "＋ Add a pen", from: "chip"
    select "Tresiba 200 U/mL (3 mL · 600 U)", from: "f-product"
    save_pen(batch: "TR9", expiry: "2028-01")
    shot("09-second-pen-insulin", height: 1000)

    find("#account-btn").click
    shot("10-account-panel", height: 900)

    # Desktop layout, for contrast with the mobile-width shots above.
    find("#account-back").click
    shot("11-desktop", width: 1100, height: 900)
  end
end
