class CreateAccountsAndCredentials < ActiveRecord::Migration[8.1]
  def change
    # uuidv7 PKs: index locality; the embedded creation time is accepted
    # activity metadata (docs/data-privacy.md "DB hygiene").
    create_table :accounts, id: :uuid, default: -> { "uuidv7()" } do |t|
      # Both columns are wrapped/derived key material produced client-side from
      # the recovery master key; the server can verify possession but cannot
      # recover the DEK from them.
      t.text :recovery_wrapped_dek
      t.string :recovery_auth_digest

      t.timestamps
      # updated_at is the idle-deletion sweep criterion.
      t.index :updated_at
    end

    create_table :webauthn_credentials, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account, type: :uuid, null: false, foreign_key: true
      t.string :external_id, null: false, index: { unique: true }
      t.text :public_key, null: false
      t.bigint :sign_count, null: false, default: 0
      # DEK wrapped by this credential's PRF-derived KEK. Written by the client
      # after the post-registration assertion; opaque to the server.
      t.text :wrapped_dek

      t.timestamps
    end
  end
end
