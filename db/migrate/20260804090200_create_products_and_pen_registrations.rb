class CreateProductsAndPenRegistrations < ActiveRecord::Migration[8.1]
  def change
    # Public reference data: powers the setup dropdowns and (later) recall
    # matching — one table, two jobs. Slug PK, human-curated.
    create_table :products, id: :string do |t|
      t.string :name, null: false
      t.string :strength, null: false, default: ""
      t.string :unit, null: false
      t.integer :decimals, null: false, default: 0
      # "numeric": the pen window shows real numbers ("counter will show 12").
      # "progress": the window is binary 0→full; the click count is the only
      # measure and copy must never imply the window shows the dose
      # (docs/design-notes.md "Dose-counter copy").
      t.string :counter_style, null: false, default: "numeric"
      t.string :capacity_label
      t.decimal :capacity_units
      t.decimal :capacity_ml
      t.integer :total_clicks
      t.integer :max_dial_clicks
      t.jsonb :common_doses, null: false, default: []
      t.decimal :default_freq_days
      t.jsonb :theme, null: false, default: {}

      t.timestamps
    end

    # Recall matching without an account⇄medicine map. Deliberately:
    #   - uuidv4 PK (no embedded timestamp to correlate with account activity)
    #   - NO account_id — the client keeps its registration IDs inside the
    #     encrypted pen blob; the row only says "some device holds batch B"
    #   - created_on is a date, quantized, never a timestamp
    # Schema lands tonight; matching/push logic is out of scope
    # (docs/data-privacy.md "The pen registry").
    create_table :push_subscriptions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.text :endpoint, null: false
      t.string :p256dh_key
      t.string :auth_key
      t.date :created_on, null: false
    end

    create_table :pen_registrations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :product, type: :string, foreign_key: true
      # Free-text product names for custom pens are admin-reviewed before any
      # use in stats (free text can contain anything).
      t.string :custom_product_name
      t.string :batch, null: false
      t.date :expiry_month, null: false
      t.references :push_subscription, type: :uuid, foreign_key: true
      t.date :created_on, null: false

      t.index [ :product_id, :batch ]
    end
  end
end
