# frozen_string_literal: true

# The admin web UI was deleted; admin operations run through the internal
# admin API (api/internal/admin) consumed by the gumroad-admin CLI. What
# remains here: impersonation, the Stripe dashboard redirect, and the
# team-member-gated Sidekiq/Flipper mounts.
namespace :admin do
  get :impersonate, to: "base#impersonate"
  delete :unimpersonate, to: "base#unimpersonate"
  get :redirect_to_stripe_dashboard, to: "base#redirect_to_stripe_dashboard", as: :redirect_to_stripe_dashboard

  constraints(lambda { |request| request.env["warden"].authenticate? && request.env["warden"].user.is_team_member? }) do
    mount SidekiqWebCSP.new(Sidekiq::Web) => :sidekiq, as: :sidekiq_web
    mount FlipperCSP.new(Flipper::UI.app(Flipper)) => :features, as: :flipper_ui
  end
end
