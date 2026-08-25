source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3", ">= 8.1.3.1"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"

# Prometheus metrics: request histograms (yabeda-rails), Puma pool gauges
# (yabeda-puma-plugin), Ruby GC/heap stats (yabeda-gc — the signal that tells
# heap growth from native growth when a container's RSS climbs), and a
# /metrics exporter on a separate in-process port (yabeda-prometheus).
# See config/puma.rb.
gem "yabeda-gc"
gem "yabeda-prometheus"
gem "yabeda-puma-plugin"
gem "yabeda-rails"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# WebAuthn ceremony verification (registration/authentication). All PRF/HKDF/
# key-wrap crypto is client-side WebCrypto — the server only verifies ceremonies
# and stores opaque wrapped keys (docs/data-privacy.md "Crypto design").
gem "webauthn", "~> 3.4"

group :development, :test do
  gem "rspec-rails", "~> 8.0"
  gem "factory_bot_rails"
end

group :test do
  gem "capybara"
  # Drives Chromium over raw CDP (no chromedriver binary exists for linux-arm64);
  # raw CDP is also how the WebAuthn virtual authenticator (PRF) is injected.
  gem "cuprite"
end

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Rails' own style guide — omakase, so style stays undebated.
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end
