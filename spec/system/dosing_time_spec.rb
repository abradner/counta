require "rails_helper"

# Unit-level coverage for the dosing-time proxy (app/javascript/dosing_time.js)
# in isolation: no signup, no pen, just the pure rounding function reached
# through the test-hooks bridge (window.countaTest, gated to the test env —
# see spec/javascript/test_hooks.js). Issue #14 introduces it; issue #37's
# next-dose forecast is expected to reuse this exact function rather than
# re-deriving the rounding rule, so it earns its own spec independent of the
# ICS flow that first needed it (see spec/system/ics_and_account_spec.rb for
# the integration-level coverage of how the proxy feeds into DTSTART/DTEND).
RSpec.describe "Dosing-time proxy: round to nearest half hour", type: :system do
  before do
    visit "/"
    wait_for_test_hooks
  end

  # Local wall-clock parts of an epoch-ms instant, read back through the same
  # Date the app itself would build — avoids any host/Ruby timezone mismatch.
  def local_parts(ms)
    page.evaluate_script(
      "(() => { const d = new Date(#{ms}); " \
      "return [d.getFullYear(), d.getMonth() + 1, d.getDate(), d.getHours(), d.getMinutes()]; })()"
    )
  end

  def rounded_parts(year, month, day, hour, minute)
    ms = page.evaluate_script(
      "window.countaTest.roundToNearestHalfHour(" \
      "new Date(#{year}, #{month - 1}, #{day}, #{hour}, #{minute}, 0).getTime())"
    )
    local_parts(ms)
  end

  it "matches the issue's own example: 17:47 rounds up to 18:00" do
    expect(rounded_parts(2026, 6, 10, 17, 47)).to eq([ 2026, 6, 10, 18, 0 ])
  end

  it "rounds x:14 down to x:00" do
    expect(rounded_parts(2026, 6, 10, 17, 14)).to eq([ 2026, 6, 10, 17, 0 ])
  end

  it "rounds the x:15 tie up to x:30" do
    expect(rounded_parts(2026, 6, 10, 17, 15)).to eq([ 2026, 6, 10, 17, 30 ])
  end

  it "rounds x:44 down to x:30" do
    expect(rounded_parts(2026, 6, 10, 17, 44)).to eq([ 2026, 6, 10, 17, 30 ])
  end

  it "rounds the x:45 tie up into the next hour" do
    expect(rounded_parts(2026, 6, 10, 17, 45)).to eq([ 2026, 6, 10, 18, 0 ])
  end

  it "leaves an exact half hour untouched" do
    expect(rounded_parts(2026, 6, 10, 17, 30)).to eq([ 2026, 6, 10, 17, 30 ])
  end

  it "wraps across midnight into the next day" do
    expect(rounded_parts(2026, 6, 10, 23, 50)).to eq([ 2026, 6, 11, 0, 0 ])
  end

  it "wraps across a month/year boundary" do
    expect(rounded_parts(2025, 12, 31, 23, 50)).to eq([ 2026, 1, 1, 0, 0 ])
  end
end
