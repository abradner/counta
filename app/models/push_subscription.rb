# Web-push delivery target for recall notifications; attached to registry
# rows, never to accounts.
class PushSubscription < ApplicationRecord
  has_many :pen_registrations

  validates :endpoint, presence: true
end
