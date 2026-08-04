# An account is anonymous by construction: a random UUID handle, no email, no
# username, no password. Everything sensitive hangs off it as ciphertext.
class Account < ApplicationRecord
  has_many :webauthn_credentials, dependent: :destroy
  has_many :pens, dependent: :destroy

  # Deliberately NO association to PenRegistration — the link lives only inside
  # the encrypted pen blob, client-side (docs/data-privacy.md "The pen registry").
end
