# frozen_string_literal: true

# Nothing on the Gumhead gateway reads body params — the controller handles
# the raw body itself. Left alone, Rails parses the body into params at the
# start of process_action, which copies seller prompts into the
# instrumentation payload (and from there into Sentry breadcrumbs), and
# ActionDispatch dumps a malformed body to the debug log before ParseError
# even raises. Pinning the body params empty here, before dispatch, means
# no component ever parses the body for these routes. Query-string
# parameters are unaffected.
class GumheadBodyParamsGuard
  def initialize(app)
    @app = app
  end

  def call(env)
    env["action_dispatch.request.request_parameters"] = {} if env["PATH_INFO"].to_s.include?("/v2/gumhead/")
    @app.call(env)
  end
end
