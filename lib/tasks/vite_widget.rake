# frozen_string_literal: true

namespace :vite do
  desc "Build the standalone widget bundles (vite.config.widget.ts) for both overlay and embed targets"
  task build_widget: :environment do
    # Expose Ruby domain constants as env vars so the Vite widget build
    # compiles the correct protocol/domain for the current RAILS_ENV.
    # Without this, vite.config.widget.ts falls back to production defaults
    # ("https" / "gumroad.com") which breaks test/staging embeds.
    ENV["PROTOCOL"]     ||= PROTOCOL     if defined?(PROTOCOL)
    ENV["DOMAIN"]       ||= DOMAIN       if defined?(DOMAIN)
    ENV["ROOT_DOMAIN"]  ||= ROOT_DOMAIN  if defined?(ROOT_DOMAIN)
    ENV["SHORT_DOMAIN"] ||= SHORT_DOMAIN if defined?(SHORT_DOMAIN)

    %w[gumroad gumroad-embed].each do |target|
      sh({ "WIDGET_TARGET" => target }, "npx vite build --config vite.config.widget.ts")
    end
  end
end

if Rake::Task.task_defined?("assets:precompile")
  Rake::Task["assets:precompile"].enhance(["vite:build_widget"])
end
