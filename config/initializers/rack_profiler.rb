# frozen_string_literal: true

require "rack-mini-profiler"

Rack::MiniProfilerRails.initialize!(Rails.application)

Rack::MiniProfiler.config.authorization_mode = :allow_authorized

Rack::MiniProfiler.config.skip_paths = [
  /#{ASSET_DOMAIN}/o,
]

Rack::MiniProfiler.config.start_hidden = true

Rack::MiniProfiler.config.storage_instance = Rack::MiniProfiler::RedisStore.new(
  connection: $redis,
  expires_in: 1.hour.in_seconds,
)

Rack::MiniProfiler.config.user_provider = ->(env) do
  request = ActionDispatch::Request.new(env)
  id = request.cookies["_gumroad_guid"] || request.remote_ip || "unknown"

  Digest::SHA256.hexdigest(id.to_s)
end

# Rack::Headers makes accessing the headers case-insensitive, so
# headers["Content-Type"] is the same as headers["content-type"]. MiniProfiler
# specifically looks for "Content-Type" and would skip injecting the profiler
# if the header is actually "content-type".
class EnsureHeadersIsRackHeadersObject
  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    response = Rack::Response[status, headers, body]

    # Debug why the original headers object is sometimes a Hash and sometimes a
    # Rack::Headers object.
    response.add_header("X-Original-Headers-Class", headers.class.name)

    response.finish
  end
end

Rails.application.config.middleware.insert_after(
  Rack::MiniProfiler,
  EnsureHeadersIsRackHeadersObject
)
