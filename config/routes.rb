Rails.application.routes.draw do
  root "home#index"

  # WebAuthn ceremonies. Registration doubles as signup (no session) and
  # add-passkey (session required — the DEK must be in client memory to wrap
  # for the new credential, so this flow only exists inside the account panel).
  scope :webauthn do
    post "registration/options", to: "webauthn_registrations#options"
    post "registration", to: "webauthn_registrations#create"
    post "authentication/options", to: "webauthn_sessions#options"
    post "authentication", to: "webauthn_sessions#create"
    delete "session", to: "webauthn_sessions#destroy"
  end

  # Kit-based recovery: possession of the recovery master key (proved via a
  # derived auth secret) grants a session + the recovery-wrapped DEK.
  post "recovery/session", to: "recoveries#create"

  # Device-level walk-away-clean action; stub tonight (no push rows exist yet).
  post "device/flush", to: "device_flushes#create"

  namespace :api do
    resources :pens, only: [ :index, :create, :update, :destroy ]
    resources :products, only: [ :index ]
    resources :credentials, only: [ :index ]
    resource :account, only: [ :destroy ]
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
