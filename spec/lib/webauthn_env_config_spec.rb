require "rails_helper"

# Unit-level coverage for the ENV-fallback logic config/environments/
# production.rb delegates to. Deliberately doesn't boot the app in the
# production environment — these are plain Ruby methods precisely so this
# spec doesn't have to.
RSpec.describe WebauthnEnvConfig do
  describe ".origin" do
    it "defaults to the canonical production origin" do
      expect(described_class.origin({})).to eq("https://counta.click")
    end

    it "is overridden by WEBAUTHN_ORIGIN" do
      expect(described_class.origin("WEBAUTHN_ORIGIN" => "https://staging.example")).to eq("https://staging.example")
    end
  end

  describe ".rp_id" do
    it "defaults to the default origin's host" do
      expect(described_class.rp_id({})).to eq("counta.click")
    end

    it "tracks an overridden origin when WEBAUTHN_RP_ID isn't set" do
      env = { "WEBAUTHN_ORIGIN" => "https://staging.example" }
      expect(described_class.rp_id(env)).to eq("staging.example")
    end

    it "is independently overridable by WEBAUTHN_RP_ID" do
      env = { "WEBAUTHN_ORIGIN" => "https://staging.example", "WEBAUTHN_RP_ID" => "other.example" }
      expect(described_class.rp_id(env)).to eq("other.example")
    end
  end

  describe ".hosts" do
    it "defaults to counta.click" do
      expect(described_class.hosts({})).to eq([ "counta.click" ])
    end

    it "is overridden by a comma-separated RAILS_HOSTS" do
      env = { "RAILS_HOSTS" => "staging.example,counta.click" }
      expect(described_class.hosts(env)).to eq([ "staging.example", "counta.click" ])
    end
  end
end
