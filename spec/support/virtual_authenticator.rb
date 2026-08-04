# Chrome-DevTools-Protocol WebAuthn virtual authenticator with PRF support.
# hasPrf + ctap2_1 is the combination the envelope depends on; proven working
# against Chromium 150 (register → enabled:true, assert → 32 deterministic
# PRF bytes) before the crypto core was built on it.
module VirtualAuthenticator
  def cdp(command, **params)
    page.driver.browser.page.command(command, **params)
  end

  def add_virtual_authenticator
    cdp("WebAuthn.enable")
    result = cdp("WebAuthn.addVirtualAuthenticator", options: {
      protocol: "ctap2",
      ctap2Version: "ctap2_1",
      transport: "internal",
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      hasPrf: true,
      automaticPresenceSimulation: true
    })
    result["authenticatorId"]
  end

  def remove_virtual_authenticator(authenticator_id)
    cdp("WebAuthn.removeVirtualAuthenticator", authenticatorId: authenticator_id)
  end

  def virtual_credentials(authenticator_id)
    cdp("WebAuthn.getCredentials", authenticatorId: authenticator_id)["credentials"]
  end

  def remove_virtual_credential(authenticator_id, credential_id)
    cdp("WebAuthn.removeCredential", authenticatorId: authenticator_id, credentialId: credential_id)
  end
end

RSpec.configure do |config|
  config.include VirtualAuthenticator, type: :system
end
