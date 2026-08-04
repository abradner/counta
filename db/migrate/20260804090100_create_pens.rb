class CreatePens < ActiveRecord::Migration[8.1]
  def change
    # One row per pen, one opaque encrypted payload (AES-256-GCM under the
    # account DEK). A blob — not a row per dose — so row counts/timestamps
    # cannot reconstruct dosing rhythm (docs/data-privacy.md "Data map").
    create_table :pens, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account, type: :uuid, null: false, foreign_key: true
      t.text :blob, null: false

      # updated_at doubles as the last-write-wins sync tiebreaker.
      t.timestamps
    end
  end
end
