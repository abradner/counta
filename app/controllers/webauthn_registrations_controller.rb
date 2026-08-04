# Passkey registration: signup (anonymous — mints a fresh account handle) or
# add-passkey (must be signed in; the client wraps the in-memory DEK for the
# new credential and sends the wrapped DEK alongside the attestation).
#
# PRF is a registration requirement (docs/data-privacy.md "Crypto design"):
# the CLIENT feature-detects it — a server can't see PRF results of create(),
# so the enforcement point is the client refusing to complete signup without
# it. The server enforces the structural half: an account can't be created
# without recovery wrap material, and a credential without a wrapped DEK is
# useless for unlock.
class WebauthnRegistrationsController < ApplicationController
  def options
    if current_account
      handle = current_account.id
      exclude = current_account.webauthn_credentials.pluck(:external_id)
    else
      handle = SecureRandom.uuid_v7
      session[:pending_handle] = handle
      exclude = []
    end

    creation_options = WebAuthn::Credential.options_for_create(
      user: {
        id: Base64.urlsafe_encode64(handle, padding: false),
        # No email/username exists by design; this is what passkey managers
        # display.
        name: "counta.click",
        display_name: "counta.click"
      },
      exclude: exclude,
      authenticator_selection: {
        resident_key: "required",       # discoverable: usernameless login
        user_verification: "required"
      }
    )
    session[:creation_challenge] = creation_options.challenge
    render json: creation_options
  end

  def create
    challenge = session.delete(:creation_challenge)
    return head :unprocessable_entity unless challenge

    webauthn_credential = WebAuthn::Credential.from_create(params.require(:credential).to_unsafe_h)
    # See the sessions controller: UV is only enforced when passed explicitly.
    webauthn_credential.verify(challenge, user_verification: true)

    if current_account
      add_credential(current_account, webauthn_credential)
    else
      signup(webauthn_credential)
    end
    render json: { account_id: current_account.id, **fresh_csrf }
  rescue WebAuthn::Error, ActiveRecord::RecordInvalid, ActionController::ParameterMissing => e
    Rails.logger.info("webauthn registration rejected: #{e.class}")
    render json: { error: "Registration could not be verified." }, status: :unprocessable_entity
  rescue StandardError => e
    # from_create parses attacker-supplied CBOR/base64 on an unauthenticated
    # endpoint; malformed input raises EOFError/KeyError/NoMethodError rather
    # than WebAuthn::Error, which would otherwise 500 with a backtrace.
    raise unless malformed_credential?(e)
    Rails.logger.info("webauthn registration malformed: #{e.class}")
    render json: { error: "Registration could not be verified." }, status: :unprocessable_entity
  end

  private

  def signup(webauthn_credential)
    handle = session.delete(:pending_handle)
    raise WebAuthn::Error, "no pending signup" unless handle

    account = nil
    ActiveRecord::Base.transaction do
      account = Account.create!(
        id: handle,
        recovery_wrapped_dek: params.require(:recovery_wrapped_dek),
        recovery_auth_digest: params.require(:recovery_auth_digest)
      )
      build_credential(account, webauthn_credential).save!
    end
    reset_session
    session[:account_id] = account.id
    @current_account = account
  end

  def add_credential(account, webauthn_credential)
    build_credential(account, webauthn_credential).save!
    touch_account_activity
  end

  def build_credential(account, webauthn_credential)
    account.webauthn_credentials.build(
      external_id: webauthn_credential.id,
      public_key: webauthn_credential.public_key,
      sign_count: webauthn_credential.sign_count,
      wrapped_dek: params.require(:wrapped_dek)
    )
  end
end
