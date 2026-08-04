# System specs drive Chromium over raw CDP via Cuprite/Ferrum — no
# chromedriver exists for linux-arm64, and raw CDP is also how the WebAuthn
# virtual authenticator is injected (see spec/support/virtual_authenticator.rb).

require "capybara/cuprite"

# Fixed port: the WebAuthn origin check is exact (config.x.webauthn_origin in
# config/environments/test.rb must match scheme+host+port).
Capybara.server_host = "127.0.0.1"
Capybara.server_port = 25_426
Capybara.app_host = "http://localhost:25426"
Capybara.default_max_wait_time = 5

Capybara.register_driver(:cuprite) do |app|
  Capybara::Cuprite::Driver.new(
    app,
    browser_path: "/usr/bin/chromium",
    headless: true,
    window_size: [ 1200, 900 ],
    timeout: 30,
    process_timeout: 30
    # Note: don't try to pin the browser locale here to stabilise date
    # assertions — Chromium's --lang doesn't drive Intl's default locale, so
    # it silently does nothing. Assert on <time datetime> instead, which is
    # locale-independent by construction (AGENTS.md §9.9).
  )
end

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :cuprite
  end

  # Rails disables forgery protection in the test env, which blinded the suite
  # to a real bug: reset_session (signup/login/recovery) rotates the CSRF
  # token, 422-ing every later POST from the still-open page (AGENTS.md §9.5).
  # System specs are full-browser, so run them with real CSRF; request specs
  # keep the env default.
  config.around(:each, type: :system) do |example|
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = false
  end
end
