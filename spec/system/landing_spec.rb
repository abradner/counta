require "rails_helper"

RSpec.describe "Landing screen", type: :system do
  # Regression (AGENTS.md §9.3): authored display rules (main{display:grid},
  # .warn{display:flex}) silently beat the hidden attribute's UA display:none,
  # so "hidden" app sections and empty error pills rendered on the landing
  # page until [hidden]{display:none !important} was added.
  it "shows only the signed-out surface — no app sections or empty alerts" do
    visit "/"

    expect(page).to have_button("Create account") # positive control: page rendered
    expect(page).not_to have_css("#pen-svg", visible: :visible)
    expect(page).not_to have_css(".warn", visible: :visible)
    expect(page).not_to have_css("#app-screen main, #dose-card", visible: :visible)
    expect(page).not_to have_text("Front of pen")
  end
end
