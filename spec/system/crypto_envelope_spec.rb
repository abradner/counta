# The envelope proof required before anything is built on top of the crypto
# core: register → unlock → add second passkey → recover via kit → decrypt,
# against a real Chromium WebAuthn implementation (virtual authenticator with
# PRF). Server-side assertions check what the DB actually holds: ciphertext
# only, one wrapped DEK per credential, plus the recovery wrap.
require "rails_helper"

RSpec.describe "Crypto envelope", type: :system do
  before do
    load Rails.root.join("db/seeds.rb")
  end

  it "registers, unlocks, adds a second passkey, and recovers via kit — decrypting at every stage" do
    visit "/"
    authenticator_id = add_virtual_authenticator

    # --- register (first-run: disclaimer → passkey+PRF → recovery kit) ---
    click_button "Create account"
    within("#disclaimer-dlg") { click_button "I understand — continue" }

    expect(page).to have_css("#kit-dlg[open]", wait: 15)
    find("#kit-words-toggle").click
    words = page.all("#kit-words li").map(&:text)
    expect(words.length).to eq(24)
    kit_account_id = find("#kit-account").text
    check "kit-saved-check"
    click_button "Continue"
    expect(page).to have_css("#setup-card", wait: 15)

    account = Account.sole
    expect(account.id).to eq(kit_account_id)
    expect(account.recovery_wrapped_dek).to be_present
    first_credential = WebauthnCredential.sole
    expect(first_credential.wrapped_dek).to be_present

    # Encrypt a probe through the real client path; the server must only ever
    # see ciphertext (positive control: the plaintext round-trips below).
    probe = "PROBE-#{SecureRandom.hex(8)}"
    page.evaluate_async_script("window.countaTest.encryptProbe(arguments[0]).then(arguments[1])", probe)
    expect(Pen.sole.blob).not_to include(probe)
    expect(Pen.sole.account_id).to eq(account.id)

    first_virtual_cred = virtual_credentials(authenticator_id).sole.fetch("credentialId")

    # --- unlock: reload drops the DEK; a fresh assertion re-derives it ---
    visit "/"
    expect(page).to have_button("Unlock with passkey", wait: 10)
    click_button "Unlock with passkey"
    expect(page).to have_css("#app-screen:not([hidden])", wait: 15)
    expect(decrypt_probe).to eq(probe)

    # --- add second passkey (requires the unlocked DEK to wrap) ---
    find("#account-btn").click
    click_button "Add a passkey"
    expect(page).to have_css("#passkey-list li", count: 2, wait: 15)

    expect(WebauthnCredential.count).to eq(2)
    second_credential = (WebauthnCredential.all - [ first_credential ]).first
    expect(second_credential.wrapped_dek).to be_present
    # Distinct KEKs ⇒ distinct wraps of the same DEK.
    expect(
      [ first_credential.wrapped_dek, second_credential.wrapped_dek, account.recovery_wrapped_dek ].uniq.length
    ).to eq(3)

    # Discoverable credentials are keyed by (rpId, userHandle), so enrolling a
    # second passkey on the SAME authenticator replaces the first one — the
    # authenticator now only holds credential #2, which forces the second
    # credential's unwrap path on the next unlock.
    remaining = virtual_credentials(authenticator_id).sole.fetch("credentialId")
    expect(remaining).not_to eq(first_virtual_cred)
    visit "/"
    click_button "Unlock with passkey"
    expect(page).to have_css("#app-screen:not([hidden])", wait: 15)
    expect(decrypt_probe).to eq(probe)

    # --- recover via kit: lose every passkey ---
    remove_virtual_authenticator(authenticator_id)
    visit "/"
    click_button "Sign out"
    expect(page).to have_button("Recover with a saved kit", wait: 10)
    click_button "Recover with a saved kit"
    fill_in "rec-account", with: kit_account_id
    fill_in "rec-words", with: words.join(" ")
    click_button "Recover"
    expect(page).to have_css("#app-screen:not([hidden])", wait: 15)
    expect(decrypt_probe).to eq(probe)

    # Post-recovery, a new passkey can be enrolled (fresh authenticator).
    add_virtual_authenticator
    find("#account-btn").click
    click_button "Add a passkey"
    expect(page).to have_css("#passkey-list li", count: 3, wait: 15)
    expect(WebauthnCredential.count).to eq(3)
  end

  it "rejects a wrong recovery kit with a uniform error" do
    visit "/"
    authenticator_id = add_virtual_authenticator
    click_button "Create account"
    within("#disclaimer-dlg") { click_button "I understand — continue" }
    expect(page).to have_css("#kit-dlg[open]", wait: 15)
    find("#kit-words-toggle").click
    kit_account_id = find("#kit-account").text
    check "kit-saved-check"
    click_button "Continue"
    expect(page).to have_css("#setup-card", wait: 15)

    remove_virtual_authenticator(authenticator_id)
    visit "/"
    click_button "Sign out"
    click_button "Recover with a saved kit"
    fill_in "rec-account", with: kit_account_id
    # Valid-checksum words for the WRONG master key: "abandon" ×23 + "art" is
    # the canonical all-zero-entropy BIP39 vector.
    fill_in "rec-words", with: ([ "abandon" ] * 23 + [ "art" ]).join(" ")
    click_button "Recover"
    expect(page).to have_text("That account ID and kit don’t match.", wait: 10)
  end

  def decrypt_probe
    page.evaluate_async_script("window.countaTest.decryptProbe().then(arguments[0])")
  end
end
