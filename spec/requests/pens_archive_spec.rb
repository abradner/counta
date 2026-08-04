# Archive state is server-authoritative: the client sends intent, the server
# stamps the time and derives the retention deadline. These are the invariants
# the UI's retention copy depends on.
require "rails_helper"

RSpec.describe "Pens API archiving", type: :request do
  let(:proof) { SecureRandom.hex(32) }
  let(:account) do
    Account.create!(recovery_wrapped_dek: "w", recovery_auth_digest: Digest::SHA256.hexdigest(proof))
  end
  let(:pen) { account.pens.create!(blob: "ciphertext") }

  before do
    post "/recovery/session", params: { account_id: account.id, proof: proof }, as: :json
    expect(response).to have_http_status(:ok)
  end

  def put_pen(**params)
    put "/api/pens/#{pen.id}", params: { blob: "ciphertext", **params }, as: :json
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  it "stamps archived_at server-side and derives purge_after from it" do
    body = put_pen(archived: true)

    pen.reload
    expect(pen.archived_at).to be_within(5.seconds).of(Time.current)
    # Both cross the wire as UTC ISO8601 for the client to render locally.
    expect(body["archived_at"]).to eq(pen.archived_at.utc.iso8601)
    expect(body["purge_after"]).to eq((pen.archived_at + 2.years).utc.iso8601)
  end

  it "does not restart the retention clock when an archived pen is saved again" do
    pen.update!(archived_at: 18.months.ago)
    original = pen.reload.archived_at

    put_pen(archived: true)

    # Re-saving must not silently extend retention past what the user was told.
    expect(pen.reload.archived_at).to eq(original)
  end

  it "clears the stamp when unarchived, and re-archiving starts a fresh window" do
    pen.update!(archived_at: 18.months.ago)

    expect(put_pen(archived: false)["archived_at"]).to be_nil
    expect(pen.reload.archived_at).to be_nil

    put_pen(archived: true)
    expect(pen.reload.archived_at).to be_within(5.seconds).of(Time.current)
  end

  it "leaves an unarchived pen with no retention deadline at all" do
    body = put_pen(archived: false)

    expect(body["archived_at"]).to be_nil
    expect(body["purge_after"]).to be_nil
    expect(pen.reload.archived_at).to be_nil
  end

  it "cannot be used to archive another account's pen" do
    other = Account.create!.pens.create!(blob: "theirs")

    put "/api/pens/#{other.id}", params: { blob: "ciphertext", archived: true }, as: :json

    expect(response).to have_http_status(:not_found)
    expect(other.reload.archived_at).to be_nil
  end
end
