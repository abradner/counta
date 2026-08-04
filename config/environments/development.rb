require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Make code changes take effect immediately without server restart.
  config.enable_reloading = true

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing.
  config.server_timing = true

  # Enable/disable Action Controller caching. By default Action Controller caching is disabled.
  # Run rails dev:cache to toggle Action Controller caching.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true
    config.public_file_server.headers = { "cache-control" => "public, max-age=#{2.days.to_i}" }
  else
    config.action_controller.perform_caching = false
  end

  # Change to :null_store to avoid any caching.
  config.cache_store = :memory_store

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # Append comments with runtime information tags to SQL queries in logs.
  config.active_record.query_log_tags_enabled = true

  # Highlight code that enqueued background job in logs.
  config.active_job.verbose_enqueue_logs = true

  # Highlight code that triggered redirect in logs.
  config.action_dispatch.verbose_redirect_logs = true

  # Suppress logger output for asset requests.
  config.assets.quiet = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # Pre-deploy testing: haproxy terminates TLS for https://counta.click and
  # forwards to this host on port 25425 as plain http.
  config.hosts << "counta.click"

  # That makes this environment PUBLICLY REACHABLE, which development mode is
  # not built for: web-console renders an interactive Ruby REPL on exception
  # pages, and it authorises by remote IP — which, behind a same-host proxy,
  # is 127.0.0.1 for every visitor on the internet. That is remote code
  # execution on the app server, and on an end-to-end-encrypted app it means
  # serving hostile JS to every user. Deny it outright; a proper deployment
  # should run RAILS_ENV=production (see docs/repo-map.md R-005).
  config.web_console.permissions = "127.0.0.255/32" if defined?(WebConsole)

  # WebAuthn is origin-bound: ceremonies signed for https://counta.click only
  # verify against that origin/RP ID (test env overrides with localhost).
  config.x.webauthn_origin = "https://counta.click"
  config.x.webauthn_rp_id = "counta.click"
end
