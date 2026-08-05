module Api
  # Blobs in, blobs out. Every query goes through current_account.pens —
  # never Pen.find — so one account's pens are structurally invisible to
  # another (AGENTS.md §4.1, R-001).
  #
  # Sync uses optimistic concurrency. A write may carry the `updated_at` the
  # client based it on; if the stored row has moved on since, the write is
  # rejected with 409 and the current row is returned so the client can merge
  # and retry. This matters more here than in most apps: the blob is a pen's
  # ENTIRE dose log, so an unconditional overwrite from a stale tab doesn't
  # lose one dose, it loses all of them — and the server can't reconstruct
  # anything, because it holds no keys.
  #
  # `expected_updated_at` is REQUIRED on update. Leaving it optional would mean
  # any older client — including a tab loaded before this shipped — silently
  # kept the old last-write-wins behaviour, so the guarantee would hold only
  # for clients that opted into it.
  class PensController < ApplicationController
    before_action :require_account!

    def index
      # Opportunistic retention sweep — no scheduler exists yet (deployment is
      # undecided), so the claim "archived pens are kept for 2 years, then
      # removed" is backed by this plus `rake pens:purge`.
      PenPurgeJob.perform_later
      pens = current_account.pens.order(:created_at)
      render json: pens.map { |pen| pen_json(pen) }
    end

    def create
      pen = current_account.pens.create!(pen_params)
      touch_account_activity
      render json: pen_json(pen), status: :created
    end

    def update
      pen = current_account.pens.find(params[:id])
      return render_conflict(pen) if stale_write?(pen)

      pen.update!(pen_params)
      touch_account_activity
      render json: pen_json(pen)
    end

    def destroy
      current_account.pens.find(params[:id]).destroy!
      touch_account_activity
      head :no_content
    end

    private

    # Compare at microsecond precision, matching what pen_json serialises —
    # a coarser comparison would silently accept writes based on a version the
    # client never saw.
    # A PUT always updates an existing row — creation goes through POST — so a
    # write with no version is a client that predates conflict detection, and
    # accepting it would reopen exactly the overwrite this exists to stop.
    # Refuse it, and hand back the current row so the caller can catch up.
    def stale_write?(pen)
      expected = params[:expected_updated_at].presence
      return true unless expected

      expected != pen.updated_at.utc.iso8601(6)
    end

    # 409 carries the winning row, so the client can merge against what's
    # actually stored rather than guessing or refetching in a second round trip.
    def render_conflict(pen)
      render json: pen_json(pen), status: :conflict
    end

    # The client sends the archive *intent*; the server stamps the time. Dates
    # and deadlines are never calculated client-side (AGENTS.md §9.6).
    #
    # Tri-state on purpose: `archived` absent means "don't touch the archive
    # state". Treating absence as false would let any write that simply
    # doesn't mention archiving silently un-archive a pen and drop it out of
    # the retention sweep forever.
    def pen_params
      attrs = { blob: params.require(:blob) }
      return attrs unless params.key?(:archived)

      attrs[:archived_at] =
        if ActiveModel::Type::Boolean.new.cast(params[:archived])
          # Re-archiving an already-archived pen must not restart its
          # retention clock, so an existing stamp wins.
          current_account.pens.find_by(id: params[:id])&.archived_at || Time.current
        end
      attrs
    end

    # All times cross the wire as ISO8601 UTC; the client formats them in the
    # viewer's local zone.
    def pen_json(pen)
      { id: pen.id, blob: pen.blob,
        archived_at: pen.archived_at&.utc&.iso8601,
        purge_after: pen.purge_after&.utc&.iso8601,
        updated_at: pen.updated_at.utc.iso8601(6) }
    end
  end
end
