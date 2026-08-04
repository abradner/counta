WebAuthn.configure do |config|
  # Origin/RP ID are per-environment (config.x.*) because WebAuthn binds
  # ceremonies to the exact origin: https://counta.click in dev/prod,
  # http://localhost:25426 under the Capybara test server.
  config.allowed_origins = [ Rails.configuration.x.webauthn_origin ]
  config.rp_id = Rails.configuration.x.webauthn_rp_id
  config.rp_name = "counta.click"
end
