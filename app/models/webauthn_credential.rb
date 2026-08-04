class WebauthnCredential < ApplicationRecord
  belongs_to :account

  validates :external_id, presence: true, uniqueness: true
  validates :public_key, presence: true
end
