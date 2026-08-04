# Optimistic concurrency on pen writes (issue #2). The blob is a pen's entire
# dose log, so an accepted stale write destroys a whole history that nobody —
# including the operator — can reconstruct.
require "rails_helper"

RSpec.describe "Pens API conflict detection", type: :request do
  let(:proof) { SecureRandom.hex(32) }
  let(:account) do
    Account.create!(recovery_wrapped_dek: "w", recovery_auth_digest: Digest::SHA256.hexdigest(proof))
  end
  let(:pen) { account.pens.create!(blob: "v1") }

  before do
    post "/recovery/session", params: { account_id: account.id, proof: proof }, as: :json
    expect(response).to have_http_status(:ok)
  end

  def version_of(record) = record.reload.updated_at.utc.iso8601(6)

  it "rejects a write based on a superseded version and keeps the stored blob" do
    stale_version = version_of(pen)
    # Another device writes in between.
    pen.update!(blob: "v2-from-other-device")

    put "/api/pens/#{pen.id}",
        params: { blob: "v2-from-stale-tab", expected_updated_at: stale_version }, as: :json

    expect(response).to have_http_status(:conflict)
    expect(pen.reload.blob).to eq("v2-from-other-device")
    # The winning row comes back so the client can merge without a second trip.
    expect(response.parsed_body["blob"]).to eq("v2-from-other-device")
    expect(response.parsed_body["updated_at"]).to eq(version_of(pen))
  end

  it "accepts a write based on the current version" do
    put "/api/pens/#{pen.id}",
        params: { blob: "v2", expected_updated_at: version_of(pen) }, as: :json

    expect(response).to have_http_status(:ok)
    expect(pen.reload.blob).to eq("v2")
  end

  it "accepts a write that doesn't claim a version (first write, or a deliberate force)" do
    put "/api/pens/#{pen.id}", params: { blob: "v2" }, as: :json

    expect(response).to have_http_status(:ok)
    expect(pen.reload.blob).to eq("v2")
  end

  it "compares at the precision it publishes" do
    # pen_json serialises microseconds; comparing anything coarser would accept
    # a write based on a version the client never actually saw.
    truncated = pen.reload.updated_at.utc.iso8601

    put "/api/pens/#{pen.id}",
        params: { blob: "v2", expected_updated_at: truncated }, as: :json

    expect(response).to have_http_status(:conflict) unless truncated == version_of(pen)
  end

  it "still refuses a conflicting write on another account's pen with 404, not 409" do
    other = Account.create!.pens.create!(blob: "theirs")

    put "/api/pens/#{other.id}",
        params: { blob: "mine", expected_updated_at: "whenever" }, as: :json

    # Scoping is checked before version — a stranger must not learn that the
    # row exists, let alone its version.
    expect(response).to have_http_status(:not_found)
    expect(other.reload.blob).to eq("theirs")
  end
end
