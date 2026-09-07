# frozen_string_literal: true

Flipper.configure do |config|
  config.adapter { Flipper::Adapters::Redis.new($redis) }
end

# Gumhead beta membership is a User flag bit, not per-actor enablement:
# flipper 1.3 caps actors at 100 per feature and the beta must grow past that.
Flipper.register(:gumhead_beta) { |actor| actor.respond_to?(:gumhead_enabled?) && actor.gumhead_enabled? }

Rails.application.config.flipper.preload = false

Flipper::UI.configuration.application_breadcrumb_href = "/"
Flipper::UI.configuration.cloud_recommendation = false
Flipper::UI.configuration.fun = false

# Flipper UI uses <script> tags to load external JS and CSS.
# FlipperCSP adds domains to existing Content Security Policy for a single route
class FlipperCSP
  def initialize(app)
    @app = app
  end

  def call(env)
    SecureHeaders.append_content_security_policy_directives(
      Rack::Request.new(env),
      {
        script_src: %w(code.jquery.com cdnjs.cloudflare.com cdn.jsdelivr.net),
        style_src: %w(cdn.jsdelivr.net)
      }
    )
    @app.call(env)
  end
end
