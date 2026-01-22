# frozen_string_literal: true

class Rack::Attack
  redis_url    = ENV.fetch("RACK_ATTACK_REDIS_HOST")
  redis_client = Redis.new(url: "redis://#{redis_url}")
  Rack::Attack.cache.store = Rack::Attack::StoreProxy::RedisStoreProxy.new(redis_client)

  class Request < ::Rack::Request
    # When the server is behind a load balancer
    def remote_ip
      @remote_ip ||= (env["HTTP_CF_CONNECTING_IP"] || env["action_dispatch.remote_ip"] || ip).to_s
    end

    def localhost?
      remote_ip == "127.0.0.1" || remote_ip == "::1"
    end

    def json_params
      @json_params ||= begin
        JSON.parse(body.read) rescue {}
      ensure
        body.rewind
      end
    end
  end

  def self.matches_path?(path:, request:)
    if path.is_a?(Regexp)
      request.path.match?(path)
    else
      request.path == path
    end
  end

  def self.throttle_identifier(path:, method:, request:, identifier:)
    identifier = path.is_a?(Regexp) ? "#{request.path}:#{identifier}" : identifier

    if matches_path?(path:, request:)
      return if method.present? && request.request_method.to_s.upcase != method.to_s.upcase

      identifier
    end
  end

  def self.throttle_name(prefix:, path:, method:)
    name = "#{prefix}:#{path}"

    method.present? ? "#{name}:#{method}" : name
  end

  def self.throttle_with_exponential_backoff(name:, requests:, period:, max_level: 5, &block_proc)
    block = Proc.new do |req|
      block_proc.call(req)
    rescue Rack::QueryParser::InvalidParameterError
      # Looks like this request contains invalid params. We already have an
      # "invalid_params" throttle rule defined below, therefore, we don't need
      # to throttle it here again.
      # Also, this request will be passed down the middleware hierarchy. Thus
      # to prevent this exception from polluting our error reporting tool
      # we will gracefully handle it in the CatchBadRequestErrors middleware.
      nil
    end

    throttle(name, limit: requests, period:, &block)

    rpm = (requests / period.to_f) * 60

    (2..max_level).each do |level|
      throttle("#{name}/#{level}", limit: (rpm * level), period: (8**level).seconds, &block)
    end
  end

  # Throttle by both IP and request parameters
  def self.throttle_by_ip_and_params(path:, requests:, period:, throttle_params:, method: nil)
    block_proc = proc { |req| throttle_identifier(path:, method:, request: req, identifier: "#{req.remote_ip}:#{throttle_params.call(req)}") }
    name = throttle_name(prefix: "/ip/params", path:, method:)

    throttle_with_exponential_backoff(name:, requests:, period:, max_level: 6, &block_proc)
  end

  # Throttle by request parameters
  def self.throttle_by_params(path:, requests:, period:, throttle_params:, method: nil)
    block_proc = proc { |req| throttle_identifier(path:, method:, request: req, identifier: "#{throttle_params.call(req)}") }
    name = throttle_name(prefix: "/params", path:, method:)

    throttle_with_exponential_backoff(name:, requests:, period:, max_level: 6, &block_proc)
  end

  # Throttle by IP with exponential backoff
  def self.throttle_by_ip(path:, requests:, period:, max_level: 5, method: nil)
    block_proc = proc { |req| throttle_identifier(path:, method:, request: req, identifier: req.remote_ip) }
    name = throttle_name(prefix: "/ip", path:, method:)

    throttle_with_exponential_backoff(name:, requests:, period:, max_level:, &block_proc)
  end

  # Throttle by IP without exponential backoff
  def self.throttle_by_ip_for_period(path:, requests:, period:, method: nil)
    name = throttle_name(prefix: "/ip/period", path:, method:)

    throttle(name, limit: requests, period:) do |req|
      throttle_identifier(path:, method:, request: req, identifier: req.remote_ip)
    end
  end

  # Throttle requests containing invalid params
  # Throttle rate: 5rpm, 30 requests/3 days, max 35 requests/24 days
  throttle_with_exponential_backoff(
    name: "invalid_params",
    requests: 5,
    period: 60.seconds,
    max_level: 7
  ) do |req|
    req.params # test that params are valid

    false
  rescue Rack::QueryParser::InvalidParameterError
    "#{req.path}:#{req.remote_ip}"
  end

  # Disable throttling for frequently used paths in staging
  if Rails.env.production?
    throttle_by_ip path: "/login", method: :post,           requests: 3,  period: 20.seconds # Initial: 9rpm,   Max: 45  requests/9 hours
    throttle_by_ip path: "/login.json",                     requests: 3,  period: 20.seconds # Initial: 9rpm,   Max: 45  requests/9 hours
    throttle_by_ip path: "/signup",                         requests: 3,  period: 20.seconds # Initial: 9rpm,   Max: 45  requests/9 hours
    throttle_by_ip path: "/signup.json",                    requests: 3,  period: 20.seconds # Initial: 9rpm,   Max: 45  requests/9 hours
    throttle_by_ip path: "/follow", method: :post,          requests: 3,  period: 20.seconds # Initial: 9rpm,   Max: 45  requests/9 hours
    throttle_by_ip path: "/follow_from_embed_form",         requests: 3,  period: 20.seconds # Initial: 9rpm,   Max: 45  requests/9 hours
    throttle_by_ip path: "/forgot_password.json",           requests: 3,  period: 20.seconds # Initial: 9rpm,   Max: 45  requests/9 hours
    throttle_by_ip path: "/forgot_password",                requests: 3,  period: 20.seconds # Initial: 9rpm,   Max: 45  requests/9 hours
    throttle_by_ip path: "/users/auth/facebook",            requests: 3,  period: 20.seconds # Initial: 9rpm,   Max: 45  requests/9 hours

    # Don't allow spammer to send confirmation emails to many random emails
    throttle_by_ip path: "/settings", requests: 3, period: 20.seconds, method: :put # Initial: 9rpm, Max: 45 requests/9 hours
  end

  throttle_by_ip path: "/",                               requests: 60, period: 30.seconds # Initial: 120rpm, Max: 600 requests/9 hours
  throttle_by_ip path: "/api/mobile/purchases/index.json", requests: 60, period: 30.seconds # Initial: 120rpm, Max: 600 requests/9 hours
  throttle_by_ip path: "/mobile/purchases/index.json",    requests: 60, period: 30.seconds # Initial: 120rpm, Max: 600 requests/9 hours
  throttle_by_ip path: "/discover",                       requests: 60, period: 30.seconds # Initial: 120rpm, Max: 600 requests/9 hours
  throttle_by_ip path: "/discover_search",                requests: 60, period: 30.seconds # Initial: 120rpm, Max: 600 requests/9 hours
  throttle_by_ip path: "/offer_codes/compute_discount",   requests: 60, period: 30.seconds # Initial: 120rpm, Max: 600 requests/9 hours
  throttle_by_ip path: "/purchases",                      requests: 40, period: 60.seconds # Initial: 40rpm,  Max: 200 requests/9 hours
  throttle_by_ip path: "/stripe/setup_intents",           requests: 40, period: 60.seconds # Initial: 40rpm,  Max: 200 requests/9 hours
  throttle_by_ip path: "/settings/credit_card",           requests: 3,  period: 20.seconds # Initial: 9rpm,   Max: 45  requests/9 hours

  throttle_by_ip_for_period path: "/purchases", requests: 50, period: 1.hour

  throttle_by_ip path: "/oauth/token", requests: 3000, period: 60.seconds # Initial: 3000rpm, Max: 15000 requests/9 hours

  # Spammers have been abusing follower's endpoints. This degrades our email reputation since we send confirmation email to each follower.
  # The following rules impose stricter and per-creator rate-limiting to prevent spammers from creating followers through a distributed attack.
  # Please see https://git.io/JfiDY for more information.
  #
  # Initial: 3rpm, Max: 18 requests/3 days (per creator, per IP)
  throttle_by_ip_and_params path: "/follow",
                            requests: 3,
                            method: :post,
                            period: 60.seconds,
                            throttle_params: Proc.new { |req| req.params["seller_id"] }

  # Initial: 3rpm, Max: 18 requests/3 days (per creator, per IP)
  throttle_by_ip_and_params path: "/follow_from_embed_form",
                            requests: 3,
                            period: 60.seconds,
                            throttle_params: Proc.new { |req| req.params["seller_id"] }

  # Initial: 10rpm, Max: 60 requests/3 days (per user)
  throttle_by_params path: "/two-factor",
                     requests: 10,
                     method: :post,
                     period: 60.seconds,
                     throttle_params: Proc.new { |req| req.params["user_id"] }

  # Initial: 10rpm, Max: 60 requests/3 days (per user)
  throttle_by_params path: "/two-factor/resend_authentication_token",
                     requests: 10,
                     method: :post,
                     period: 60.seconds,
                     throttle_params: Proc.new { |req| req.params["user_id"] }

  # Initial: 10rpm, Max: 60 requests/3 days (per user)
  throttle_by_params path: "/two-factor/verify",
                     requests: 10,
                     period: 60.seconds,
                     throttle_params: Proc.new { |req| req.params["user_id"] }

  # Initial: 4rpm, Max: 24 requests/9 hours
  throttle_by_params path: "/forgot_password.json",
                     method: :post,
                     requests: 4,
                     period: 60.seconds,
                     throttle_params: Proc.new { |req| req.json_params.is_a?(Hash) && req.json_params.dig("user", "email").presence }

  # Initial: 4rpm, Max: 24 requests/9 hours
  throttle_by_params path: "/forgot_password",
                     method: :post,
                     requests: 4,
                     period: 60.seconds,
                     throttle_params: Proc.new { |req| req.json_params.is_a?(Hash) && req.json_params.dig("user", "email").presence }

  # Throttle requests to Sales API with slow pagination
  throttle("/api/v2/sales", limit: 10, period: 1.second) do |req|
    req.remote_ip if req.path.ends_with?("/v2/sales") && req.params["page"].to_i > 10
  end

  # Throttle POST requests to /login by login param
  #
  # Key: "rack::attack:#{Time.now.to_i/:period}:logins/login:#{req.login}"
  #
  # Note: This creates a problem where a malicious user could intentionally
  # throttle logins for another user and force their login requests to be
  # denied, but that's not very common and shouldn't happen to you. (Knock
  # on wood!)
  throttle("logins/login", limit: 3, period: 20.seconds) do |req|
    if req.path == "/login.json" && req.post?
      # return the login if present, nil otherwise
      req.params["user"] && req.params["user"]["login"].presence
    end
  end

  # Throttle POST requests to /:username/affiliate_requests
  #
  # Initial: 10rpm, Max: 50 requests/9 hours
  throttle_by_ip path: /\A\/[[:alnum:]]+\/affiliate_requests\z/,
                 method: :post,
                 requests: 10,
                 period: 60.seconds

  # Throttle comment requests on posts
  #
  # Initial: 5rpm, Max: 25 requests/9 hours (per post, per IP)
  throttle_by_ip path: /\A\/posts\/.+\/comments\z/,
                 method: :post,
                 requests: 5,
                 period: 60.seconds

  # Initial: 5rpm, Max: 25 requests/9 hours (per post, per IP)
  throttle_by_ip path: /\A\/posts\/.+\/comments\/.+\z/,
                 method: :put,
                 requests: 5,
                 period: 60.seconds

  # Throttle requests to resend receipts
  # Initial: 2rpm, Max: 20 requests/9 hours (per purchase, per IP)
  throttle_by_ip path: /\A\/(purchases|service_charges)\/.+\/resend_receipt\z/,
                 method: :post,
                 requests: 2,
                 period: 60.seconds

  # Throttle community chat messages
  # 60 requests per 60 seconds (per community, per IP)
  throttle_by_ip_for_period path: /\A\/internal\/communities\/.*\/chat_messages\z/,
                            method: :post,
                            requests: 60,
                            period: 60.seconds

  # Throttle AI product details generation requests
  # 10 requests per 60 seconds (per IP)
  throttle_by_ip_for_period path: "/internal/ai_product_details_generations",
                            method: :post,
                            requests: 10,
                            period: 60.seconds

  # Throttle ACME challenge requests
  # 120 requests per 60 seconds (per IP)
  throttle_by_ip_for_period path: /\A\/\.well-known\/acme-challenge\//,
                            requests: 120,
                            period: 60.seconds

  # Do not throttle for health check requests
  safelist("allow from localhost", &:localhost?)
end

# Log blocked events

ActiveSupport::Notifications.subscribe(/throttle.rack_attack/) do |_name, _start, _finish, _request_id, payload|
  req = payload[:request]
  if req.env["rack.attack.match_type"] == :throttle
    request_headers = { "CF-RAY" => req.env["HTTP_CF_RAY"], "X-Amzn-Trace-Id" => req.env["HTTP_X_AMZN_TRACE_ID"] }
    Rails.logger.info "[Rack::Attack][Blocked] remote_ip: \"#{req.remote_ip}\", path: \"#{req.path}\", headers: #{request_headers.inspect}"
  end
end
