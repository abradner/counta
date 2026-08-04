require "rails_helper"

RSpec.describe PenPurgeJob do
  let(:account) { Account.create! }

  it "deletes only pens whose retention TTL has passed" do
    expired = account.pens.create!(blob: "ct", purge_after: Date.current - 1)
    due_today = account.pens.create!(blob: "ct", purge_after: Date.current)
    future = account.pens.create!(blob: "ct", purge_after: Date.current + 1)
    active = account.pens.create!(blob: "ct") # no TTL — an in-use pen

    described_class.perform_now

    expect(Pen.where(id: expired.id)).not_to exist
    # Boundary: a pen whose TTL is today is kept until tomorrow.
    expect(Pen.where(id: [ due_today.id, future.id, active.id ]).count).to eq(3)
  end

  it "leaves the owning account and its credentials untouched" do
    account.webauthn_credentials.create!(external_id: "c1", public_key: "pk")
    account.pens.create!(blob: "ct", purge_after: Date.current - 1)

    described_class.perform_now

    expect(Account.where(id: account.id)).to exist
    expect(account.webauthn_credentials.count).to eq(1)
  end
end
