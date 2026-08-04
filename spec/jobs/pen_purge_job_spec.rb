require "rails_helper"

RSpec.describe PenPurgeJob do
  let(:account) { Account.create! }

  it "deletes only pens archived longer ago than the retention window" do
    expired = account.pens.create!(blob: "ct", archived_at: 2.years.ago - 1.day)
    just_inside = account.pens.create!(blob: "ct", archived_at: 2.years.ago + 1.hour)
    recent = account.pens.create!(blob: "ct", archived_at: 1.day.ago)
    in_use = account.pens.create!(blob: "ct") # never archived

    described_class.perform_now

    expect(Pen.where(id: expired.id)).not_to exist
    # Boundary + the case that matters most: an unarchived pen is never swept,
    # however old it is.
    expect(Pen.where(id: [ just_inside.id, recent.id, in_use.id ]).count).to eq(3)
  end

  it "never sweeps an in-use pen, however old" do
    ancient = account.pens.create!(blob: "ct")
    ancient.update_columns(created_at: 10.years.ago, updated_at: 10.years.ago)

    described_class.perform_now

    expect(Pen.where(id: ancient.id)).to exist
  end

  it "leaves the owning account and its credentials untouched" do
    account.webauthn_credentials.create!(external_id: "c1", public_key: "pk")
    account.pens.create!(blob: "ct", archived_at: 3.years.ago)

    described_class.perform_now

    expect(Account.where(id: account.id)).to exist
    expect(account.webauthn_credentials.count).to eq(1)
  end

  it "derives the retention deadline server-side rather than storing it" do
    pen = account.pens.create!(blob: "ct", archived_at: Time.utc(2026, 8, 4, 14, 30))

    expect(pen.purge_after).to eq(Time.utc(2028, 8, 4, 14, 30))
    expect(Pen.column_names).not_to include("purge_after")
  end
end
