# Issue #3: ciphertext length leaked the dose count.
#
# The blob-per-pen design exists so that row counts and timestamps can't
# reconstruct someone's dosing rhythm — but AES-GCM ciphertext is plaintext + 16
# bytes, and the payload grew by roughly one JSON entry per dose. So
# `SELECT length(blob)` estimated how many doses a person had logged, straight
# out of a database dump, with no key involved.
require "rails_helper"

RSpec.describe "Blob padding", type: :system do
  before do
    load Rails.root.join("db/seeds.rb")
    visit "/"
    add_virtual_authenticator
    sign_up_through_first_run
    select "Wegovy 2.4 mg (4 doses · 9.6 mg · 3 mL)", from: "f-product"
    save_pen
  end

  it "never changes stored size by a dose-sized amount" do
    sizes = [ Pen.sole.blob.length ]
    6.times do
      log_dose
      sizes << Pen.sole.reload.blob.length
    end

    # Asserted as "no dose-sized step" rather than "one constant value", so
    # that a future payload which happens to straddle a bucket boundary
    # doesn't fail a spec whose property still holds. A dose is ~138 bytes; a
    # bucket is 4096. Anything in between is the leak.
    deltas = sizes.each_cons(2).map { |a, b| b - a }
    expect(deltas).to all(satisfy { |d| d.zero? || d > 4000 }),
      "stored size moved by a dose-sized amount (#{sizes.inspect}) — that leaks how many doses exist"
  end

  it "still round-trips the data it padded" do
    log_dose
    log_dose

    visit "/"
    click_button "Unlock with passkey"
    expect(page).to have_css("#dose-card:not([hidden])", wait: 15)

    # Padding is trailing whitespace inside the JSON, so decrypt-and-parse is
    # unaffected — the history is intact and the pen still works.
    expect(page).to have_css("#history li", count: 2)
    expect(find("#stats").text).to include((296 - 16).to_s)
  end

  it "grows in discrete steps, and stays flat within a step" do
    # The mechanism, stated as a property: as the payload outgrows a bucket the
    # stored size jumps once, then stays flat again. Size therefore never
    # tracks the dose count — it only ever reveals which bucket you're in.
    sizes = []
    12.times do |batch|
      10.times { |i| append_dose(format("2026-03-%02d", (i % 28) + 1)) }
      sizes << Pen.sole.reload.blob.length
    end

    distinct = sizes.uniq
    expect(distinct.length).to be < sizes.length,
      "every batch changed the size (#{sizes.inspect}) — padding isn't holding"
    expect(sizes).to eq(sizes.sort), "size should never shrink"
    # Each step up is one bucket's worth, not one dose's worth. Stored size is
    # base64, so a 4 KiB bucket is ~5461 characters and successive steps can
    # differ by a byte or two purely from base64 rounding — that rounding is
    # not content-dependent.
    bucket_in_base64 = (4096 * 4 / 3.0).ceil
    steps = distinct.each_cons(2).map { |a, b| b - a }
    steps.each do |step|
      expect(step).to be_within(8).of(bucket_in_base64),
        "step of #{step} isn't a whole bucket (#{steps.inspect}) — size may track content"
    end
  end

  def append_dose(date)
    page.evaluate_async_script(
      "window.countaTest.appendDose(arguments[0]).then(arguments[1])", date
    )
  end
end
