# Unlinkable recall registry row: "some device holds product P batch B".
# Structurally has NO account association — do not add one; the client keeps
# its registration IDs inside the encrypted pen blob
# (docs/data-privacy.md "The pen registry").
class PenRegistration < ApplicationRecord
  belongs_to :product, optional: true
  belongs_to :push_subscription, optional: true

  validates :batch, presence: true
  validates :expiry_month, presence: true
end
