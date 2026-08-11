# frozen_string_literal: true

require "digest"

class Rack::Attack
  redis_url    = ENV.fetch("RACK_ATTACK_REDIS_HOST")
  redis_client = Redis.new(url: "redis://#{redis_url}")
  Rack::Attack.cache.store = Rack::Attack::StoreProxy::RedisProxy.new(redis_client)

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
    rescue Rack::QueryParser::InvalidParameterError, TypeError, Rack::Multipart::EmptyContentError
      # Malformed request bodies (bad form encoding, or a multipart POST with an
      # empty/truncated body) make `req.params` raise. These requests come from
      # scanners and broken clients, not real users — skip this throttle rule for
      # them instead of crashing the middleware with a 500. The dedicated
      # "invalid_params" throttle below still rate-limits these senders.
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
  rescue Rack::QueryParser::InvalidParameterError, Rack::Multipart::EmptyContentError
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

    # Creating a brand account sends a Devise confirmation email to whatever
    # address is submitted, so without a limit a flag-enabled creator could use
    # it to send unsolicited email to arbitrary addresses. Same rate as the
    # other email-sending endpoints above. Both the plain and .json paths are
    # throttled because the route accepts a format suffix (same reason /login
    # and /login.json each have an entry).
    throttle_by_ip path: "/sellers/brand_accounts",      requests: 3, period: 20.seconds, method: :post # Initial: 9rpm, Max: 45 requests/9 hours
    throttle_by_ip path: "/sellers/brand_accounts.json", requests: 3, period: 20.seconds, method: :post # Initial: 9rpm, Max: 45 requests/9 hours

    # Gumroad Walks: each successful realtime token gives the client up to 2h of OpenAI
    # Realtime usage against our key, so a leaked/replayed JWS is capped here at ~$10/IP/hr.
    # `max_level: 1` skips the backoff tiers — with a 1-hour base period `rpm * level` rounds
    # to <1 and would block the very first escalation. Both `/api/v2/walks/...` and
    # `/v2/walks/...` need entries since `api_routes` is mounted under both prefixes.
    # Temporarily relaxed while debugging the App Attest reinstall flow (repeated reinstalls
    # burn the 3/hr attestation cap below and surface as "attestation rejected"); restore once fixed.
    # throttle_by_ip path: "/api/v2/walks/realtime_tokens", method: :post, requests: 5, period: 1.hour, max_level: 1
    # throttle_by_ip path: "/v2/walks/realtime_tokens",     method: :post, requests: 5, period: 1.hour, max_level: 1
    # throttle_by_ip path: "/api/v2/walks/synthesis",       method: :post, requests: 5, period: 1.hour, max_level: 1
    # throttle_by_ip path: "/v2/walks/synthesis",           method: :post, requests: 5, period: 1.hour, max_level: 1

    # App Attest bootstrap. `attestations` is once-per-install on the happy path, so 3/IP/hr
    # lets a NAT recover from transient failures without letting a botnet fan out keys.
    # `challenges` fires once per walks call plus once per attestation, so it needs more headroom.
    # throttle_by_ip path: "/api/v2/walks/app_attest/attestations", method: :post, requests: 3,  period: 1.hour, max_level: 1
    # throttle_by_ip path: "/v2/walks/app_attest/attestations",     method: :post, requests: 3,  period: 1.hour, max_level: 1
    # throttle_by_ip path: "/api/v2/walks/app_attest/challenges",   method: :post, requests: 60, period: 1.hour, max_level: 1
    # throttle_by_ip path: "/v2/walks/app_attest/challenges",       method: :post, requests: 60, period: 1.hour, max_level: 1
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
  # Keyed per (token, file), not per token: one purchase legitimately fans out across every
  # file in a bundle or course, so a per-token counter would 429 a buyer part-way through a
  # large product. max_level: 1 keeps a stuck client from earning the multi-hour backoff tiers.
  # The file capture stops at a dot so `.json`/`.xml` format variants share one bucket —
  # route segments never contain dots, so anything after one is a format suffix.
  # GET/HEAD only: this route never serves other verbs, and matching every method let an
  # unauthenticated POST flood exhaust a buyer's own download bucket.
  throttle_with_exponential_backoff(name: "mobile_url_redirect_download/token", requests: 60, period: 60.seconds, max_level: 1) do |req|
    next unless %w[GET HEAD].include?(req.request_method)

    m = req.path.match(%r{\A/(?:api/)?mobile/url_redirects/download/(?<token>[^/]+)/(?<file>[^/.]+)})
    "#{m[:token]}/#{m[:file]}" if m
  end

  throttle_by_ip_for_period path: "/purchases", requests: 50, period: 1.hour

  # Help Center contact form. Each submission emails the support inbox, so an unthrottled IP
  # could flood support and burn email reputation. `max_level: 1` skips the backoff tiers,
  # which with a 1-minute base period would derive limits stricter than the base and block
  # legit retries. Match by regex (like the OAuth device-flow throttles below) so a format
  # suffix (`/help/contact.xml`) doesn't bypass the limit, keyed on IP alone so every suffix
  # shares one counter.
  throttle_with_exponential_backoff(name: "help_center_contact/ip", requests: 3, period: 60.seconds, max_level: 1) do |req|
    req.remote_ip if req.path.match?(%r{\A/help/contact(?:\.[^/]+)?\z}) && req.post?
  end

  # Each hit that matches purchases sends a grouped receipt email to the given address,
  # unauthenticated. Throttle by IP and, separately, by target email — the harm is to the
  # RECIPIENT, so an abuser rotating IPs must not be able to mailbomb one buyer
  # (gumroad-private#1869). Every route accepts a format suffix (`.json`, `.xml`, ...) —
  # match by regex like the throttles around this one so every suffix shares one counter
  # instead of each format getting its own budget. Lives outside the production-only block
  # above deliberately: like the help-center rule, an email-abuse limit belongs in staging too.
  GROUPED_RECEIPT_LOOKUP_PATHS = %w[/charge_data /license_key_lookup_data /paypal_charge_data].index_with do |path|
    /\A#{Regexp.escape(path)}(?:\.[^\/]+)?\z/
  end.freeze
  GROUPED_RECEIPT_LOOKUP_PATHS.each do |path, path_regexp|
    throttle_with_exponential_backoff(name: "/ip:#{path}", requests: 3, period: 20.seconds) do |req|
      req.remote_ip if req.path.match?(path_regexp)
    end
  end
  # One shared per-recipient budget across both grouped-receipt endpoints — they send the
  # same email, so separate budgets would double the ceiling. Initial: 6rpm, Max: 36
  # requests/3 days — roomy enough for a buyer retrying a lookup, still a hard ceiling on
  # emails one address can be sent (the mailer's 24h send-once claim bounds duplicates).
  # Strip before keying: purchases.email compares under a PAD SPACE collation, so
  # "a@b.com " matches the victim's rows while landing in a fresh throttle bucket.
  throttle_with_exponential_backoff(name: "/params:grouped_receipt:email", requests: 6, period: 60.seconds, max_level: 6) do |req|
    if req.path.match?(GROUPED_RECEIPT_LOOKUP_PATHS["/charge_data"]) || req.path.match?(GROUPED_RECEIPT_LOOKUP_PATHS["/license_key_lookup_data"])
      req.params["email"].to_s.strip.downcase.presence
    end
  end

  throttle_with_exponential_backoff(name: "oauth_device_code/ip", requests: 20, period: 60.seconds) do |req|
    req.remote_ip if req.path.match?(%r{\A/oauth/device/code(?:\.[^/]+)?\z}) && req.post?
  end
  throttle_with_exponential_backoff(name: "oauth_device_authorization_lookup/ip", requests: 30, period: 60.seconds) do |req|
    if req.path.match?(%r{\A/oauth/device(?:\.[^/]+)?\z}) && ["GET", "HEAD"].include?(req.request_method)
      req.remote_ip
    end
  end
  throttle_with_exponential_backoff(name: "oauth_device_authorization_decision/ip", requests: 10, period: 60.seconds) do |req|
    req.remote_ip if req.path.match?(%r{\A/oauth/device(?:\.[^/]+)?\z}) && req.post?
  end
  throttle_with_exponential_backoff(name: "oauth_token/ip", requests: 3000, period: 60.seconds) do |req|
    req.remote_ip if req.path.match?(%r{\A/oauth/token(?:\.[^/]+)?\z})
  end
  throttle("oauth_device_token/ip/device_code", limit: 120, period: 60.seconds) do |req|
    if req.path.match?(%r{\A/oauth/token(?:\.[^/]+)?\z}) && req.post?
      body_params = req.media_type&.include?("json") ? req.json_params : req.POST
      request_params = body_params.is_a?(Hash) ? body_params.merge(req.GET) : req.GET
      if request_params["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code"
        "#{req.remote_ip}:#{Digest::SHA256.hexdigest(request_params["device_code"].to_s)}"
      end
    end
  rescue Rack::QueryParser::InvalidParameterError, TypeError, Rack::Multipart::EmptyContentError
    nil
  end

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

  # Catalogue slices for the gumroad:products bridge on custom profile pages
  # (gumroad-private#1691). Seller is identified by request host or /:username prefix, both
  # part of the identifier here. 30/min covers the largest real catalogue (1,430 products =
  # 14 pages) in one burst while bounding a hostile page's loop; each slice is served from
  # the profile-data cache after the first read.
  throttle_by_ip_and_params path: %r{\A/(?:[^/]+/)?landing/products\z},
                            requests: 30,
                            method: :get,
                            period: 60.seconds,
                            throttle_params: Proc.new { |req| req.host }

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

  # Initial: 10rpm, Max: 60 requests/3 days (per user)
  throttle_by_params path: "/two-factor/switch_to_email",
                     requests: 10,
                     method: :post,
                     period: 60.seconds,
                     throttle_params: Proc.new { |req| req.params["user_id"] }

  # Initial: 10rpm, Max: 60 requests/3 days (per user)
  throttle_by_params path: "/two-factor/switch_to_recovery",
                     requests: 10,
                     method: :post,
                     period: 60.seconds,
                     throttle_params: Proc.new { |req| req.params["user_id"] }

  # Initial: 10rpm, Max: 60 requests/3 days (per user)
  throttle_by_params path: "/two-factor/switch_to_authenticator",
                     requests: 10,
                     method: :post,
                     period: 60.seconds,
                     throttle_params: Proc.new { |req| req.params["user_id"] }

  # Initial: 10rpm, Max: 60 requests/3 days (per user)
  throttle_by_params path: "/settings/totp/confirm",
                     requests: 10,
                     method: :post,
                     period: 60.seconds,
                     throttle_params: Proc.new { |req| req.env["warden"]&.user&.id }

  # Initial: 10rpm, Max: 60 requests/3 days (per user)
  throttle_with_exponential_backoff(name: "/params:/settings/passkeys/registration_options:POST", requests: 10, period: 60.seconds, max_level: 6) do |req|
    req.env["warden"]&.user&.id if req.path.match?(%r{\A/settings/passkeys/registration_options(?:\.[^/]+)?\z}) && req.post?
  end

  # Initial: 10rpm, Max: 60 requests/3 days (per user)
  throttle_with_exponential_backoff(name: "/params:/settings/passkeys:POST", requests: 10, period: 60.seconds, max_level: 6) do |req|
    req.env["warden"]&.user&.id if req.path.match?(%r{\A/settings/passkeys(?:\.[^/]+)?\z}) && req.post?
  end

  # Passkey login is unauthenticated, so throttle by IP. Initial: 10rpm, Max: 60 requests/3 days (per IP)
  throttle_with_exponential_backoff(name: "/ip:/login/passkey/options:POST", requests: 10, period: 60.seconds, max_level: 6) do |req|
    req.remote_ip if req.path.match?(%r{\A/login/passkey/options(?:\.[^/]+)?\z}) && req.post?
  end

  # Initial: 10rpm, Max: 60 requests/3 days (per IP)
  throttle_with_exponential_backoff(name: "/ip:/login/passkey:POST", requests: 10, period: 60.seconds, max_level: 6) do |req|
    req.remote_ip if req.path.match?(%r{\A/login/passkey(?:\.[^/]+)?\z}) && req.post?
  end

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
  rescue Rack::QueryParser::InvalidParameterError, TypeError, Rack::Multipart::EmptyContentError
    nil
  end

  # Throttle POST /login by the submitted login param, so a botnet can't dodge the by-IP
  # login throttle by rotating IPs against one account. Trade-off: an attacker who knows a
  # victim's login can also throttle that victim's own login attempts.
  throttle("logins/login", limit: 3, period: 20.seconds) do |req|
    if req.path == "/login.json" && req.post?
      # return the login if present, nil otherwise
      req.params["user"] && req.params["user"]["login"].presence
    end
  rescue Rack::QueryParser::InvalidParameterError, TypeError, Rack::Multipart::EmptyContentError
    nil
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
  throttle_by_ip_for_period path: /\A\/communities\/[^\/]+\/chat_messages\z/,
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

  # Initial: 10rpm, Max: 50 requests/9 hours
  throttle_by_ip path: /\A\/(api\/)?v2\/products(\.\w+)?\z/, method: :post, requests: 10, period: 60.seconds

  # A comps call aggregates over the whole public index, so it is pricier than a product read.
  # Initial: 30rpm, Max: 150 requests/9 hours
  throttle_by_ip path: /\A\/(api\/)?v2\/products\/comps(\.\w+)?\z/, method: :get, requests: 30, period: 60.seconds

  # Initial: 30rpm, Max: 150 requests/9 hours
  throttle_by_ip path: /\A\/(api\/)?v2\/products\/[^\/]+(\.\w+)?\z/, method: :put, requests: 30, period: 60.seconds
  throttle_by_ip path: /\A\/(api\/)?v2\/products\/[^\/]+(\.\w+)?\z/, method: :patch, requests: 30, period: 60.seconds

  # Per-token layer on top of the per-IP rules above. Blocks the IP-rotation
  # bypass and gives token-level attribution when an agent goes off the rails.
  v2_product_token = Proc.new do |req|
    req.params["access_token"].presence || req.env["HTTP_AUTHORIZATION"].to_s[/\Abearer\s+(\S+)/i, 1]
  end
  throttle_by_params path: /\A\/(api\/)?v2\/products\/[^\/]+(\.\w+)?\z/, method: :put, requests: 30, period: 60.seconds, throttle_params: v2_product_token
  throttle_by_params path: /\A\/(api\/)?v2\/products\/[^\/]+(\.\w+)?\z/, method: :patch, requests: 30, period: 60.seconds, throttle_params: v2_product_token
  throttle_by_params path: /\A\/(api\/)?v2\/products\/comps(\.\w+)?\z/, method: :get, requests: 30, period: 60.seconds, throttle_params: v2_product_token

  # Preview is a non-mutating dry run intended for iteration, so it gets a
  # higher ceiling than PUT/PATCH. Same per-IP + per-token layering.
  # Initial: 60rpm, Max: 300 requests/9 hours
  throttle_by_ip path: /\A\/(api\/)?v2\/products\/[^\/]+\/preview_custom_html(\.\w+)?\z/, method: :post, requests: 60, period: 60.seconds
  throttle_by_params path: /\A\/(api\/)?v2\/products\/[^\/]+\/preview_custom_html(\.\w+)?\z/, method: :post, requests: 60, period: 60.seconds, throttle_params: v2_product_token

  # Profile custom HTML mirrors the product custom_html limits: the agent-driven
  # PUT (publish) and the CPU-heavy preview sanitizer need the same per-IP +
  # per-token ceilings. The token extractor above is generic, so it's reused.
  # Initial: 30rpm, Max: 150 requests/9 hours
  throttle_by_ip path: /\A\/(api\/)?v2\/user\/custom_html(\.\w+)?\z/, method: :put, requests: 30, period: 60.seconds
  throttle_by_ip path: /\A\/(api\/)?v2\/user\/custom_html(\.\w+)?\z/, method: :patch, requests: 30, period: 60.seconds
  throttle_by_params path: /\A\/(api\/)?v2\/user\/custom_html(\.\w+)?\z/, method: :put, requests: 30, period: 60.seconds, throttle_params: v2_product_token
  throttle_by_params path: /\A\/(api\/)?v2\/user\/custom_html(\.\w+)?\z/, method: :patch, requests: 30, period: 60.seconds, throttle_params: v2_product_token

  # Initial: 60rpm, Max: 300 requests/9 hours
  throttle_by_ip path: /\A\/(api\/)?v2\/user\/preview_custom_html(\.\w+)?\z/, method: :post, requests: 60, period: 60.seconds
  throttle_by_params path: /\A\/(api\/)?v2\/user\/preview_custom_html(\.\w+)?\z/, method: :post, requests: 60, period: 60.seconds, throttle_params: v2_product_token

  # Media uploads: each POST can synchronously download up to 10 MB from a remote URL
  # (CreatePublicMediaService), making this one of the priciest v2 endpoints — unthrottled,
  # it ties up workers and bandwidth. 20/10min is plenty for a creator (or the store agent)
  # building a page. Keyed by OAuth token (IP-keyed fallback for tokenless probes) so
  # rotating IPs doesn't bypass it. Matches both `/api/v2/media` and `/v2/media` prefixes,
  # mirroring the products/custom_html throttles above.
  #
  # `max_level: 1` skips the backoff tiers: with a 10-minute base period the derived rpm is
  # 2, so level 2 would allow only 4 requests/64s — stricter than the base limit (same trap
  # as the walks throttles above).
  v2_media_path = /\A\/(api\/)?v2\/media(\.\w+)?\z/
  throttle_by_ip path: v2_media_path, method: :post, requests: 20, period: 10.minutes, max_level: 1
  throttle_with_exponential_backoff(name: "media_uploads/token", requests: 20, period: 10.minutes, max_level: 1) do |req|
    if req.path.match?(v2_media_path) && req.post?
      token = req.params["access_token"].presence || req.env["HTTP_AUTHORIZATION"].to_s[/\Abearer\s+(\S+)/i, 1]
      token.presence
    end
  end

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
