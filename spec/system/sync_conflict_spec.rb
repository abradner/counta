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

  it "keeps both of two identical same-day doses that predate dose ids" do
    # Legacy entries have no identity beyond their contents, so two identical
    # doses on one date share a merge key. Deduping by key would delete one
    # even though both devices agree it happened.
    page.evaluate_async_script(<<~JS)
      (async () => {
        const [row] = await window.countaTest.rows();
        const data = await window.countaTest.decryptRow(row);
        data.history = [
          { date: "2026-01-10", clicks: 8, units: 0.26 },
          { date: "2026-01-10", clicks: 8, units: 0.26 }
        ];
        await window.countaTest.writeRow(row, data);
      })().then(arguments[0])
    JS

    # Order matters: this tab must LOAD the legacy history first, and only
    # then fall behind. Reloading after the other device writes would leave it
    # current, no conflict would occur, and the merge under test would never
    # run — which is exactly how the first version of this spec passed with
    # the merge broken.
    visit "/"
    click_button "Unlock with passkey"
    expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

    page.evaluate_async_script("window.countaTest.simulateOtherDevice('2026-02-01').then(arguments[0])")
    log_dose # now stale -> conflict -> merge

    history = page.evaluate_async_script("window.countaTest.historyFromServer().then(arguments[0])")
    same_day = history.select { |h| h["date"] == "2026-01-10" }
    expect(same_day.length).to eq(2), "a legacy duplicate dose was silently dropped"
  end

  it "does not clear the archive marker when a stale tab saves a dose" do
    log_dose
    # Another device archives the pen while this tab is open.
    page.evaluate_async_script("window.countaTest.archiveElsewhere().then(arguments[0])")
    expect(Pen.sole.archived_at).to be_present

    # This tab, which still thinks the pen is active, saves a dose.
    log_dose

    # The retry must not carry this tab's stale "not archived" idea.
    expect(Pen.sole.reload.archived_at).to be_present
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
