# The scenario issue #2 describes, end to end: a tab left open while another
# device logs a dose. Before conflict detection the open tab's next write
# silently replaced the whole dose history with its own stale copy.
require "rails_helper"

RSpec.describe "Stale-tab sync", type: :system do
  before do
    load Rails.root.join("db/seeds.rb")
    visit "/"
    add_virtual_authenticator
    sign_up_through_first_run
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    save_pen
  end

  it "keeps both devices' doses when an open tab writes over a newer version" do
    log_dose # this tab, dose 1
    expect(Pen.sole.blob).to be_present

    # Another device logs a dose. This tab knows nothing about it and its
    # cached version is now stale.
    other_count = page.evaluate_async_script(
      "window.countaTest.simulateOtherDevice('2026-01-15').then(arguments[0])"
    )
    expect(other_count).to eq(2)

    # The open tab logs another dose. Its write is based on the superseded
    # version, so it conflicts, merges and retries — without the user seeing
    # anything go wrong.
    log_dose
    expect(page).to have_css("#history li", minimum: 2, wait: 10)

    history = page.evaluate_async_script(
      "window.countaTest.historyFromServer().then(arguments[0])"
    )

    # All three doses survive: two from this tab, one from the other device.
    expect(history.length).to eq(3)
    expect(history.map { |h| h["date"] }).to include("2026-01-15")
    # ...and the merged history is what the UI is showing.
    expect(find("#stats").text).to include((296 - (8 + 8 + 8)).to_s)
  end

  it "does not duplicate a dose when the same history is merged twice" do
    log_dose
    page.evaluate_async_script("window.countaTest.simulateOtherDevice('2026-01-15').then(arguments[0])")
    log_dose # merges

    before = page.evaluate_async_script("window.countaTest.historyFromServer().then(arguments[0])").length

    # A further write from the same tab must not re-add the merged entries.
    page.evaluate_async_script("window.countaTest.simulateOtherDevice('2026-02-20').then(arguments[0])")
    log_dose

    after = page.evaluate_async_script("window.countaTest.historyFromServer().then(arguments[0])")
    expect(after.length).to eq(before + 2) # one from the other device, one here
    expect(after.map { |h| h["id"] }.uniq.length).to eq(after.length)
  end
end
