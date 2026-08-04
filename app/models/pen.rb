# The blob is AES-256-GCM ciphertext under the account DEK; the server stores
# and returns it, never interprets it. All access goes through
# account.pens — never an unscoped Pen.find (AGENTS.md §4.1, R-001).
class Pen < ApplicationRecord
  belongs_to :account

  validates :blob, presence: true
end
