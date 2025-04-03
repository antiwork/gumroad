# frozen_string_literal: true

class CatchBadRequestErrors
  def initialize(app)
    @app = app
  end

  def call(env)
    @app.call(env)
  rescue ActionController::BadRequest
    if env["HTTP_ACCEPT"].include?("application/json")
      [400, { "Content-Type" => "application/json" }, [{ success: false }.to_json]]
    else
      [400, { "Content-Type" => "text/html" }, []]
    end
  end
end
