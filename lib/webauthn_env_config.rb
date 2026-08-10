# Derives the production `config.hosts` allowlist and WebAuthn
# origin/RP ID from ENV, defaulting to the canonical counta.click values so
# the real deploy is unchanged unless something overrides it.
#
# This is a genuinely-optional tuning knob, not required config — the
# AGENTS.md "Configuration" fail-fast rule (no fallback defaults for
# *required* config) doesn't apply here. The override exists so a staging
# hostname on the Athena cluster can smoke-test boot and passkey ceremony
# *creation* (WebAuthn binds to an exact origin) before DNS cutover, without
# needing counta.click's own TLS/DNS pointed at the new deploy.
#
# Pulled out of config/environments/production.rb into a plain class so the
# ENV-fallback logic is unit-testable without booting the app in the
# production environment — see spec/lib/webauthn_env_config_spec.rb.
module WebauthnEnvConfig
  DEFAULT_ORIGIN = "https://counta.click"
  DEFAULT_HOSTS = "counta.click"

  module_function

  # WEBAUTHN_ORIGIN — scheme+host(+port) the passkey ceremony is bound to.
  def origin(env = ENV)
    env.fetch("WEBAUTHN_ORIGIN", DEFAULT_ORIGIN)
  end

  # WEBAUTHN_RP_ID — defaults to the origin's host (the common case: RP ID
  # is just the hostname), independently overridable for the rarer case
  # where a deploy wants an RP ID that isn't simply the origin's host.
  def rp_id(env = ENV, origin: origin(env))
    env.fetch("WEBAUTHN_RP_ID", URI(origin).host)
  end

  # RAILS_HOSTS — comma-separated allowlist for Rails' Host header check.
  def hosts(env = ENV)
    env.fetch("RAILS_HOSTS", DEFAULT_HOSTS).split(",")
  end
end
