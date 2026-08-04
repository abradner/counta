# Recovery-kit login. The kit's master key never reaches the server; the
# client derives a proof secret (HKDF, "counta/recovery-auth/v1") and the
# server stores only its SHA-256 digest. Possession of the proof grants a
# session plus the recovery-wrapped DEK — decryption still happens client-side.
#
# The bare Account lookup here is the auth bootstrap itself (there is no user
# to scope by yet); access is gated on the 256-bit proof, and failure is a
# uniform 401 so account existence doesn't leak.
class RecoveriesController < ApplicationController
  def create
    account = Account.find_by(id: params.require(:account_id))
    proof = params.require(:proof)

    unless account&.recovery_auth_digest.present? &&
           ActiveSupport::SecurityUtils.secure_compare(
             Digest::SHA256.hexdigest(proof), account.recovery_auth_digest
           )
      return head :unauthorized
    end

    reset_session
    session[:account_id] = account.id
    account.touch
    render json: { account_id: account.id, recovery_wrapped_dek: account.recovery_wrapped_dek,
                   **fresh_csrf }
  end
end
