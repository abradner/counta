class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  # The only identity the server ever has: an anonymous account UUID in the
  # session cookie. Every pen/dose read or write MUST go through
  # current_account's associations (AGENTS.md §4.1, R-001).
  def current_account
    @current_account ||= Account.find_by(id: session[:account_id]) if session[:account_id]
  end
  helper_method :current_account

  def require_account!
    head :unauthorized unless current_account
  end

  # Touch = "this account is alive" for the 2-year idle-deletion sweep, which
  # keys off accounts.updated_at.
  def touch_account_activity
    current_account&.touch
  end

  # Every endpoint that calls reset_session rotates the CSRF token, orphaning
  # the one in the page's <meta> tag — include this in the JSON response so
  # the client can swap it in (AGENTS.md §9.5).
  def fresh_csrf
    { csrf_token: form_authenticity_token }
  end
end
