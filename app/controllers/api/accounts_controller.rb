module Api
  # Delete account & all data: one call, full cascade (credentials, pens).
  # Pen-registry rows will join the cascade client-side once registrations
  # exist — their IDs live inside the encrypted blobs, so the client deletes
  # them before calling this (docs/data-privacy.md "Account deletion").
  class AccountsController < ApplicationController
    before_action :require_account!

    def destroy
      current_account.destroy!
      reset_session
      render json: fresh_csrf
    end
  end
end
