# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_04_140000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accounts", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "recovery_auth_digest"
    t.text "recovery_wrapped_dek"
    t.datetime "updated_at", null: false
    t.index ["updated_at"], name: "index_accounts_on_updated_at"
  end

  create_table "pen_registrations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "batch", null: false
    t.date "created_on", null: false
    t.string "custom_product_name"
    t.date "expiry_month", null: false
    t.string "product_id"
    t.uuid "push_subscription_id"
    t.index ["product_id", "batch"], name: "index_pen_registrations_on_product_id_and_batch"
    t.index ["product_id"], name: "index_pen_registrations_on_product_id"
    t.index ["push_subscription_id"], name: "index_pen_registrations_on_push_subscription_id"
  end

  create_table "pens", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "archived_at"
    t.text "blob", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_pens_on_account_id"
    t.index ["archived_at"], name: "index_pens_on_archived_at"
  end

  create_table "products", id: :string, force: :cascade do |t|
    t.string "capacity_label"
    t.decimal "capacity_ml"
    t.decimal "capacity_units"
    t.jsonb "common_doses", default: [], null: false
    t.string "counter_style", default: "numeric", null: false
    t.datetime "created_at", null: false
    t.integer "decimals", default: 0, null: false
    t.decimal "default_freq_days"
    t.integer "max_dial_clicks"
    t.string "name", null: false
    t.string "strength", default: "", null: false
    t.jsonb "theme", default: {}, null: false
    t.integer "total_clicks"
    t.string "unit", null: false
    t.datetime "updated_at", null: false
  end

  create_table "push_subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "auth_key"
    t.date "created_on", null: false
    t.text "endpoint", null: false
    t.string "p256dh_key"
  end

  create_table "webauthn_credentials", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.string "external_id", null: false
    t.text "public_key", null: false
    t.bigint "sign_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.text "wrapped_dek"
    t.index ["account_id"], name: "index_webauthn_credentials_on_account_id"
    t.index ["external_id"], name: "index_webauthn_credentials_on_external_id", unique: true
  end

  add_foreign_key "pen_registrations", "products"
  add_foreign_key "pen_registrations", "push_subscriptions"
  add_foreign_key "pens", "accounts"
  add_foreign_key "webauthn_credentials", "accounts"
end
