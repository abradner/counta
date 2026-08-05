# Pin npm packages by running ./bin/importmap

pin "application"
pin "app"
pin "auth"
pin "api"
pin "crypto"
pin "passkeys"
pin "ics"
pin "i18n"
pin "wordlist"

# Test-only, so it is never pinned — and therefore never fetched or parsed —
# outside the test environment. See app/javascript/test_hooks.js.
pin "test_hooks" if Rails.env.test?
