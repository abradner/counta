# R-001: one account's pens must be structurally invisible to another.
# Sessions are established through the real recovery endpoint (the only
# non-WebAuthn login path), so nothing is stubbed.
require "rails_helper"

RSpec.describe "Pens API owner scoping", type: :request do
  def create_account(proof)
    Account.create!(
      recovery_wrapped_dek: "wrapped-#{SecureRandom.hex(8)}",
      recovery_auth_digest: Digest::SHA256.hexdigest(proof)
    )
  end

  def sign_in(account, proof)
    post "/recovery/session", params: { account_id: account.id, proof: proof }, as: :json
    expect(response).to have_http_status(:ok)
  end

  let(:proof_a) { SecureRandom.hex(32) }
  let(:proof_b) { SecureRandom.hex(32) }
  let(:account_a) { create_account(proof_a) }
  let(:account_b) { create_account(proof_b) }
  let!(:pen_a) { account_a.pens.create!(blob: "ciphertext-a") }

  it "denies every cross-account access to another owner's pen" do
    sign_in(account_b, proof_b)

    get "/api/pens"
    expect(response.parsed_body).to eq([]) # not account A's pen

    put "/api/pens/#{pen_a.id}", params: { blob: "overwritten" }, as: :json
    expect(response).to have_http_status(:not_found)

    delete "/api/pens/#{pen_a.id}"
    expect(response).to have_http_status(:not_found)

    expect(pen_a.reload.blob).to eq("ciphertext-a")
  end

  it "serves the owner their own pen (positive control)" do
    sign_in(account_a, proof_a)

    get "/api/pens"
    expect(response.parsed_body.map { |p| p["id"] }).to eq([ pen_a.id ])

    put "/api/pens/#{pen_a.id}",
        params: { blob: "updated-ciphertext",
                  expected_updated_at: pen_a.reload.updated_at.utc.iso8601(6) }, as: :json
    expect(response).to have_http_status(:ok)
    expect(pen_a.reload.blob).to eq("updated-ciphertext")
  end

  it "requires a session at all" do
    get "/api/pens"
    expect(response).to have_http_status(:unauthorized)

    put "/api/pens/#{pen_a.id}", params: { blob: "nope" }, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects recovery with a wrong proof, uniformly" do
    post "/recovery/session", params: { account_id: account_a.id, proof: "wrong" }, as: :json
    wrong_proof = [ response.status, response.body ]

    post "/recovery/session", params: { account_id: SecureRandom.uuid, proof: proof_a }, as: :json
    missing_account = [ response.status, response.body ]

    expect(wrong_proof.first).to eq(401)
    # Identical responses for wrong-proof vs nonexistent-account: account
    # existence doesn't leak through the recovery endpoint.
    expect(missing_account).to eq(wrong_proof)
  end
end
