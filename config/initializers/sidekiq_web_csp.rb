# frozen_string_literal: true

class SidekiqWebCSP
  def initialize(app)
    @app = app
  end

  def call(env)
    SecureHeaders.append_content_security_policy_directives(
      Rack::Request.new(env),
      {
        script_src: %w('unsafe-inline')
      }
    )
    @app.call(env)
  end
end
