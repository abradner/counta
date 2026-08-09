# Dose-plan presets (issue #21) are public reference data about a product,
# exactly like `common_doses` — a transcription aid, never applied to anyone's
# pen automatically. Each preset carries its own source URL and verification
# date, so "is this still what the label says?" is answerable without
# re-deriving it (the provenance pattern issue #19 asks for).
#
# Nothing about a user's plan lands here: the plan a person actually follows
# lives inside their encrypted pen blob and the server never sees it.
class AddPlanPresetsToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :plan_presets, :jsonb, null: false, default: []
  end
end
