module Api
  # Blobs in, blobs out. Every query goes through current_account.pens —
  # never Pen.find — so one account's pens are structurally invisible to
  # another (AGENTS.md §4.1, R-001). Sync is last-write-wins: a PUT simply
  # overwrites; updated_at is the tiebreaker the client compares against.
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
