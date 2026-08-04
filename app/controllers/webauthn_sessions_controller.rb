# Usernameless login: the discoverable credential tells us who is asserting.
# The same ceremony powers "unlock" after a reload — the client re-runs it to
# re-obtain the PRF output (which never leaves the client) and we hand back
# the wrapped DEK for that credential.
class WebauthnSessionsController < ApplicationController
  def options
    get_options = WebAuthn::Credential.options_for_get(user_verification: "required")
    session[:authentication_challenge] = get_options.challenge
    render json: get_options
  end

  def create
    challenge = session.delete(:authentication_challenge)
    return head :unprocessable_entity unless challenge

    webauthn_credential = WebAuthn::Credential.from_get(params.require(:credential).to_unsafe_h)
    stored = WebauthnCredential.find_by(external_id: webauthn_credential.id)
    return head :unauthorized unless stored

    # user_verification: true is required to actually CHECK the UV flag —
    # webauthn-ruby only verifies it when asked, so requesting
    # userVerification: "required" in the options proves nothing on its own
    # (the client is attacker-controlled). A passkey is the sole factor here.
    webauthn_credential.verify(
      challenge,
      public_key: stored.public_key,
      sign_count: stored.sign_count,
      user_verification: true
    )
    stored.update!(sign_count: webauthn_credential.sign_count)

    reset_session
    session[:account_id] = stored.account_id
    stored.account.touch
    render json: { account_id: stored.account_id, wrapped_dek: stored.wrapped_dek, **fresh_csrf }
  rescue WebAuthn::Error, ActionController::ParameterMissing => e
    Rails.logger.info("webauthn authentication rejected: #{e.class}")
    render json: { error: "Sign-in could not be verified." }, status: :unauthorized
  rescue StandardError => e
    raise unless malformed_credential?(e)
    Rails.logger.info("webauthn authentication malformed: #{e.class}")
    render json: { error: "Sign-in could not be verified." }, status: :unauthorized
  end

  def destroy
    reset_session
    render json: fresh_csrf
  end
end
