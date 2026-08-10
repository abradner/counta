require "rails_helper"
require "rake"

# `rake pens:purge` (lib/tasks/pens.rake) is the CLI entry point a k8s
# CronJob invokes for the retention sweep — issue #6. It has to run the
# purge synchronously (no queue hop to lose on a one-shot pod) and let a
# failure propagate as a nonzero exit, or a broken predicate would silently
# never sweep instead of paging anyone. Same care as PenPurgeJob itself
# (R-004): a bug here either leaks unswept data past retention or, in the
# failure-swallowing direction, destroys data nobody can restore.
RSpec.describe "pens:purge rake task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("pens:purge")
  end

  after { Rake::Task["pens:purge"].reenable }

  let(:account) { Account.create! }

  it "runs the purge synchronously" do
    expired = account.pens.create!(blob: "ct", archived_at: 2.years.ago - 1.day)
    kept = account.pens.create!(blob: "ct") # never archived

    Rake::Task["pens:purge"].invoke

    expect(Pen.where(id: expired.id)).not_to exist
    expect(Pen.where(id: kept.id)).to exist
  end

  it "propagates a failure so the process (and a CronJob running it) exits nonzero" do
    allow(Pen).to receive(:retention_expired).and_raise("boom")

    expect { Rake::Task["pens:purge"].invoke }.to raise_error("boom")
  end
end
