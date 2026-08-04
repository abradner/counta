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

    # purge_after is the client-set retention TTL for archived pens (the
    # archive state itself stays inside the encrypted blob). Nil = keep.
    def pen_params
      { blob: params.require(:blob), purge_after: params[:purge_after].presence }
    end

    def pen_json(pen)
      { id: pen.id, blob: pen.blob, purge_after: pen.purge_after&.to_s,
        updated_at: pen.updated_at.iso8601(6) }
    end
  end
end
