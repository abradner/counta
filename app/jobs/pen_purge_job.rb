# Retention sweep: deletes pen rows whose client-set TTL (purge_after) has
# passed — the mechanism behind "archived pens are kept for 2 years".
#
# Deliberate exception to AGENTS.md §4.1 owner-scoping: a retention sweep has
# no requesting user to scope by. It reads no ciphertext and selects purely on
# the plaintext TTL the owner's client set.
#
# Scheduling: enqueued opportunistically from Api::PensController#index (so
# the claim holds without deploy-time infra) and available as `rake
# pens:purge` for a real scheduler once deployment is decided.
class PenPurgeJob < ApplicationJob
  queue_as :default

  def perform
    Pen.retention_expired.delete_all
  end
end
