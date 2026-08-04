# Shared system-spec flows. Each returns after the app screen is reachable.
module CountaFlows
  # Full first-run: disclaimer → passkey (virtual authenticator must already
  # be added) → recovery-kit ceremony. Lands in setup mode (no pens yet).
  # Returns the kit words + account id for recovery scenarios.
  def sign_up_through_first_run
    click_button "Create account"
    within("#disclaimer-dlg") { click_button "I understand — continue" }
    expect(page).to have_css("#kit-dlg[open]", wait: 15)
    find("#kit-words-toggle").click # words live behind the optional toggle
    words = page.all("#kit-words li").map(&:text)
    account_id = find("#kit-account").text
    check "kit-saved-check"
    click_button "Continue"
    expect(page).to have_css("#setup-card", wait: 15)
    { words: words, account_id: account_id }
  end

  # Saves a pen from setup mode with the currently selected product.
  # The month input can't be keystroked headlessly (locale-formatted typing),
  # so its value is set directly; the app still reads it through its own path.
  def save_pen(batch: "LP1234", expiry: "2027-06")
    fill_in "f-batch", with: batch
    page.execute_script(
      "document.getElementById('f-expiry').value = arguments[0];" \
      "document.getElementById('f-expiry').dispatchEvent(new Event('change', { bubbles: true }))",
      expiry
    )
    expect(page.evaluate_script("document.getElementById('f-expiry').value")).to eq(expiry)
    click_button "Save pen"
    expect(page).to have_css("#dose-card:not([hidden])", wait: 15)
  end

  def log_dose
    click_button "Dose now"
    within("#confirm-dlg") { click_button "Yes, I dosed" }
    expect(page).to have_css("#history li strong", wait: 10)
  end
end

RSpec.configure do |config|
  config.include CountaFlows, type: :system
end
