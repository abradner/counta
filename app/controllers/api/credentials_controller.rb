module Api
  # Passkey list for the account panel. Add happens via the WebAuthn
  # registration flow; removal is out of scope tonight (the can't-remove-last-
  # credential-without-confirmed-kit rule ships with it).
  class CredentialsController < ApplicationController
    before_action :require_account!

    def index
      render json: current_account.webauthn_credentials.order(:created_at).map { |c|
        { id: c.id, created_at: c.created_at.iso8601 }
      }
    end
  end
end
