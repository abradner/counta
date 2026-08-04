# The blob is AES-256-GCM ciphertext under the account DEK; the server stores
# and returns it, never interprets it. All access goes through
# account.pens — never an unscoped Pen.find (AGENTS.md §4.1, R-001).
class Pen < ApplicationRecord
  # How long an archived pen's history is kept before PenPurgeJob deletes it.
  # Single source of truth: the retention copy the UI shows is derived from
  # this, never restated client-side.
  ARCHIVE_RETENTION = 2.years

  belongs_to :account

  validates :blob, presence: true

  scope :retention_expired, -> { where(archived_at: ..ARCHIVE_RETENTION.ago) }

  def archived? = archived_at.present?

  # Deadline is derived, never stored — one calculation, server-side, in a
  # real time zone rather than browser-local arithmetic.
  def purge_after = archived_at && (archived_at + ARCHIVE_RETENTION)
end
