# The compare-then-write race (Codex, PR #13). Two writes based on the same
# version must not both succeed, or the second silently replaces a whole dose
# history that nobody can reconstruct.
#
# This drives the controller's update path directly against real, separate
# database connections, because the defect only exists between two concurrent
# transactions — a sequential test cannot see it. Transactional fixtures are
# off for this file: the second connection has to be able to observe what the
# first committed.
require "rails_helper"

RSpec.describe "Concurrent pen writes", type: :model do
  self.use_transactional_tests = false

  let!(:account) { Account.create! }
  let!(:pen) { account.pens.create!(blob: "v1") }

  after { Pen.delete_all; Account.delete_all } # pens reference accounts

  # Mirrors Api::PensController#update: lock, compare, write.
  def attempt_write(expected_version, new_blob, barrier)
    account.pens.transaction do
      row = account.pens.lock.find(pen.id)
      barrier&.call # both threads arrive here holding the same expected version
      if expected_version == row.updated_at.utc.iso8601(6)
        row.update!(blob: new_blob)
        :written
      else
        :conflict
      end
    end
  end

  it "lets exactly one of two writes based on the same version win" do
    version = pen.reload.updated_at.utc.iso8601(6)
    started = Queue.new
    results = Queue.new

    threads = %w[thread-a thread-b].map do |name|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          # Both threads read the same version before either commits, which is
          # the window the row lock has to close.
          results << attempt_write(version, "written-by-#{name}", -> { started << name })
        end
      rescue StandardError => e
        results << e
      end
    end
    threads.each { |t| t.join(10) }

    outcomes = Array.new(results.size) { results.pop }
    expect(outcomes).to contain_exactly(:written, :conflict),
      "expected one write and one conflict, got #{outcomes.inspect} — " \
      "both succeeding means a dose history was silently overwritten"

    # And the surviving blob is one of the two, not a torn mix.
    expect(pen.reload.blob).to match(/\Awritten-by-thread-[ab]\z/)
  end

  it "serialises the second writer behind the first rather than interleaving" do
    version = pen.reload.updated_at.utc.iso8601(6)

    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        attempt_write(version, "first", -> { sleep 0.2 })
      end
    end
    sleep 0.05 # let the first thread take the lock
    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        attempt_write(version, "second", nil)
      end
    end

    expect(first.value).to eq(:written)
    # The second only gets the row after the first commits, so it sees the new
    # version and refuses — rather than overwriting on a stale read.
    expect(second.value).to eq(:conflict)
    expect(pen.reload.blob).to eq("first")
  end
end
