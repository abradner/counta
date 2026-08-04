# Structural guarantees from docs/data-privacy.md, pinned so a future
# migration can't quietly undo them.
require "rails_helper"

RSpec.describe "Structural privacy guarantees" do
  describe PenRegistration do
    it "has no account linkage, by construction" do
      expect(PenRegistration.column_names).not_to include("account_id")
      expect(PenRegistration.reflect_on_all_associations.map(&:name)).not_to include(:account)
    end

    it "uses uuidv4 PKs (no embedded timestamp to correlate)" do
      registration = PenRegistration.create!(batch: "LP1", expiry_month: Date.new(2027, 6, 1),
                                             created_on: Date.current)
      # Version nibble: uuidv7 would be "7" here.
      expect(registration.id[14]).to eq("4")
    end

    it "records a quantized date, never a timestamp" do
      expect(PenRegistration.column_names).not_to include("created_at")
      expect(PenRegistration.columns_hash["created_on"].type).to eq(:date)
    end
  end

  describe Account do
    it "uses uuidv7 PKs (index locality; creation time is accepted metadata)" do
      account = Account.create!
      expect(account.id[14]).to eq("7")
    end

    it "cascades deletion to credentials and pens" do
      account = Account.create!
      account.webauthn_credentials.create!(external_id: "cred-1", public_key: "pk")
      account.pens.create!(blob: "ciphertext")

      account.destroy!

      expect(WebauthnCredential.count).to eq(0)
      expect(Pen.count).to eq(0)
    end

    it "stores no plaintext contact or identity fields" do
      expect(Account.column_names).to match_array(
        %w[id recovery_wrapped_dek recovery_auth_digest created_at updated_at]
      )
    end
  end

  describe "request log filtering (AGENTS.md §4.2)" do
    it "filters every sensitive field the API accepts" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      filtered = filter.filter(
        blob: "ciphertext", wrapped_dek: "wrap", recovery_wrapped_dek: "wrap2",
        batch: "LP1234", expiry: "2027-06", expiry_month: "2027-06",
        custom_product_name: "Ozempic", proof: "abc123", credential: { id: "x" },
        # positive control: a benign key must survive filtering
        counter_style: "progress"
      )
      expect(filtered[:counter_style]).to eq("progress")
      filtered.except(:counter_style).each do |key, value|
        expect(value.to_s).to include("FILTERED"), "expected #{key} to be filtered, got #{value.inspect}"
      end
    end
  end
end
