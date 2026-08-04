# Retention sweep: deletes pens archived longer ago than
# Pen::ARCHIVE_RETENTION — the mechanism behind "archived pens are kept for
# 2 years". The deadline is derived server-side from the server-stamped
# `archived_at`; the client only ever sends an archive intent, and cannot
# supply or backdate a timestamp (AGENTS.md §9.6).
#
# Deliberate exception to AGENTS.md §4.1 owner-scoping: a retention sweep has
# no requesting user to scope by. It reads no ciphertext and selects purely on
# that plaintext marker. A bug in the predicate destroys data nobody can
# restore, because the server holds no keys — treat changes to
# Pen.retention_expired with the same care as an auth change (R-004).
#
# Scheduling is BEST-EFFORT, not guaranteed: there is no scheduler yet
# (deployment is undecided), so this is enqueued opportunistically from
# Api::PensController#index and available as `rake pens:purge`. An account
# nobody ever opens again is therefore not swept on time. Tracked as an issue;
# don't describe this as "automatic" until a scheduler exists.
class PenPurgeJob < ApplicationJob
  queue_as :default

  def perform
    Pen.retention_expired.delete_all
  end
end
