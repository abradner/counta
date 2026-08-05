# Issue #29: the test hooks used to ship in the production bundle, gated only
# at execution. This pins the claim that they no longer do — the comment
# asserting it was previously false, which is the failure principle 1 names.
require "rails_helper"

RSpec.describe "Test hooks isolation" do
  HOOKS = Rails.root.join("spec/javascript/test_hooks.js")

  it "lives outside the application's asset path" do
    expect(HOOKS).to exist
    expect(Rails.root.join("app/javascript/test_hooks.js")).not_to exist,
      "hooks are back in app/javascript, where they'd be served to everyone"
  end

  it "is only on the asset path in test" do
    # The asset load path is what decides whether the file can be served or
    # precompiled at all, so this is the assertion carrying the guarantee.
    expect(Rails.application.config.assets.paths.map(&:to_s))
      .to include(Rails.root.join("spec/javascript").to_s)

    %w[development production].each do |env|
      expect(Rails.root.join("config/environments/#{env}.rb").read)
        .not_to include("spec/javascript"),
        "#{env}.rb puts test-only JS on the asset path"
    end
  end

  it "is pinned only in test" do
    importmap = Rails.root.join("config/importmap.rb").read
    expect(importmap).to match(/pin "test_hooks" if Rails\.env\.test\?/),
      "an unconditional pin would ship the module to every browser"
  end

  it "is reached through a gate the layout only opens in test" do
    layout = Rails.root.join("app/views/layouts/application.html.erb").read
    expect(layout).to include("Rails.env.test?")
    expect(Rails.root.join("app/javascript/app.js").read)
      .to include('import("test_hooks")')
  end
end
