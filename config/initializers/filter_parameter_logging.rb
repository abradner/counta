# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # Counta: pen/dose data is sensitive health data and must never appear in
  # request logs, ciphertext included (AGENTS.md §4.2). Partial matches cover
  # blob, wrapped_dek, batch, expiry/expiry_month, custom_product_name,
  # recovery proof, and WebAuthn ceremony payloads.
  :blob, :dek, :batch, :expiry, :product_name, :proof, :prf,
  :attestation, :assertion, :credential
]
