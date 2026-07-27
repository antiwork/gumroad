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

    # Gumroad Walks: realtime token creation is an *expensive* endpoint — each
    # successful response gives the client up to 2h of OpenAI Realtime usage
    # against our key. JWS verification is the primary gate, but a leaked or
    # replayed JWS would otherwise be unbounded — IP throttling caps that
    # blast radius at ~$10/IP/hr of OpenAI spend. 5 req/IP/hour is generous
    # for real users (1-2 walks/day).
    #
    # `max_level: 1` skips the exponential-backoff tiers — with a 1-hour base
    # period, `rpm * level` rounds to <1 and Rack::Attack would block the very
    # first request that escalates. The base 5/hour limit is already strict.
    #
    # Both `/api/v2/walks/...` (gumroad.com) and `/v2/walks/...` (api.gumroad.com)
    # need throttles since `api_routes` is mounted under both prefixes.
    # Temporarily relaxed while debugging the App Attest reinstall flow, where a
    # fresh install can burn the 3/hr attestation cap during repeated testing
    # and get a 429 the client surfaces as "attestation rejected." Restored in a
    # follow-up once the reinstall bug is fixed — these cap OpenAI/Anthropic
    # spend and prevent attested-key fan-out.
    # throttle_by_ip path: "/api/v2/walks/realtime_tokens", method: :post, requests: 5, period: 1.hour, max_level: 1
    # throttle_by_ip path: "/v2/walks/realtime_tokens",     method: :post, requests: 5, period: 1.hour, max_level: 1
    # throttle_by_ip path: "/api/v2/walks/synthesis",       method: :post, requests: 5, period: 1.hour, max_level: 1
    # throttle_by_ip path: "/v2/walks/synthesis",           method: :post, requests: 5, period: 1.hour, max_level: 1

    # App Attest bootstrap. `attestations` is genuinely once-per-install on the
    # happy path; cap at 3/IP/hr so a single corporate NAT can recover from
    # transient failures but a botnet can't fan out attested keys.
    # `challenges` is one-per-request on every walks call + once per
    # attestation, so it needs more headroom.
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
  throttle_by_ip path: "/stripe/setup_intents",           requests: 40, period: 60.seconds # Initial: 40rpm,  Max: 200 requests/9 hours
  throttle_by_ip path: "/settings/credit_card",           requests: 3,  period: 20.seconds # Initial: 9rpm,   Max: 45  requests/9 hours

  # Checkout. Buyers submit orders to `POST /orders` (OrdersController#create) and
  # `POST /orders/prepare`. There is no `POST /purchases` route — `PurchasesController`
  # has no `create` action — so the two `/purchases` rules that used to live here were
  # matching a path nothing posts to, leaving checkout entirely unthrottled. These
  # replace them at the same limits, pointed at the routes checkout actually uses.
  #
  # Matched by regex because checkout is mounted on several hosts/prefixes
  # (gumroad.com, custom domains, and the short domain all include
  # `product_info_and_purchase_routes`) and the route accepts a format suffix, so an
  # exact string compare on "/orders" would miss `/orders.json` and every
  # non-primary-host variant. Keyed on IP alone so all variants share one counter.
  CHECKOUT_ORDER_PATH = %r{\A/orders(?:/prepare)?(?:\.[^/]+)?\z}
  # Free checkout attempts allowed per product per hour, across all source IPs.
  CHECKOUT_FREE_PRODUCT_HOURLY_LIMIT = 600
  CHECKOUT_FREE_PRODUCT_THROTTLE = "checkout_orders/free_product"
  CHECKOUT_FREE_PRODUCT_PERIOD = 1.hour
  # Initial: 40rpm, Max: 200 requests/9 hours
  throttle_with_exponential_backoff(name: "checkout_orders/ip", requests: 40, period: 60.seconds) do |req|
    req.remote_ip if req.path.match?(CHECKOUT_ORDER_PATH) && req.post?
  end
  throttle("checkout_orders/ip/period", limit: 50, period: 1.hour) do |req|
    req.remote_ip if req.path.match?(CHECKOUT_ORDER_PATH) && req.post?
  end

  # Per-product cap on FREE checkouts, on top of the per-IP rules above.
  #
  # The per-IP limits do nothing against a proxy pool: an operator renting thousands of
  # residential IPs stays under every per-IP budget while hammering one product. That is
  # exactly how a $0 product was used as an open email relay — each checkout sends the
  # buyer's address a receipt from our transactional sending domain, so a walked list of
  # scraped addresses turns free checkouts into bulk unsolicited mail on our reputation
  # and with our branding.
  #
  # So cap checkout attempts per product per hour, keyed on the product permalink rather
  # than the source IP. 600/hour is far above anything organic (a product genuinely
  # getting 600 free claims in an hour is a launch we would hear about, and the window
  # resets) and far below the ~16-29K/hour this abuse sustained.
  #
  # Two deliberate scoping decisions, both about keeping the blast radius of a shared
  # counter small. A budget shared across all source IPs is inherently something a
  # stranger can spend on a seller's behalf: the middleware runs before the app, so it
  # cannot know whether a request would have become a real purchase, and a rejected
  # request costs the same budget as an accepted one.
  #
  # 1. Only FREE line items (`perceived_price_cents == "0"`) are counted, so nobody can
  #    ever be 429'd out of a PAID purchase by someone else's traffic. That is also
  #    where the abuse lives — a paid checkout is self-limiting because it needs a card
  #    that actually charges.
  # 2. An attacker cannot escape the cap by claiming a non-zero price for a free
  #    product: `perceived_price_cents` is the same field
  #    `OrdersController#all_free_products_without_captcha?` reads, and a non-zero value
  #    there means reCAPTCHA is no longer skipped. So the traffic is either
  #    cheap-and-capped or captcha-gated, with no third option.
  #
  # The residual exposure is that 600 free-checkout attempts against one product can
  # spend that product's hour, delaying free claims from real buyers until the window
  # rolls. That is the trade we want: a free claim that has to be retried later is
  # recoverable, mailing a scraped list from our sending domain is not.
  #
  # No exponential-backoff tiers here: with a 1-hour base period the derived rpm is 10, so
  # a level-2 tier would allow only 20 requests per 64 seconds — stricter than the base
  # limit, and it would block a legitimate burst (the same trap the media-upload and walks
  # throttles above document).

  # Every free product in the cart, so a cart can't dodge the cap by ordering its items
  # a particular way. Public so specs can exercise it against the request shapes that
  # reach it in production.
  def self.free_checkout_permalinks(req)
    return [] unless req.path.match?(CHECKOUT_ORDER_PATH) && req.post?

    # The checkout frontend posts a JSON body (`utils/request.ts` sets
    # `Content-Type: application/json` and `JSON.stringify`s the payload), and
    # `Rack::Request#params` only parses FORM-encoded bodies — it would return nothing
    # for a real checkout and this cap would never fire. Read `json_params` for JSON
    # requests, the same way the device-grant throttle above does. Note that specs
    # posting `params: { ... }` default to form encoding, so a spec exercising only
    # that path cannot catch this — there is a JSON-content-type example for it.
    body_params = req.media_type&.include?("json") ? req.json_params : req.POST
    line_items = body_params.is_a?(Hash) ? body_params["line_items"] : nil
    # Rails serializes an array of line items as either a JSON array or, form-encoded,
    # a hash keyed by index — accept both, and ignore anything else rather than raising
    # (a raise here would take down the middleware for every request on this path).
    line_items = line_items.values if line_items.is_a?(Hash)
    return [] unless line_items.is_a?(Array)

    line_items.filter_map do |item|
      next unless item.is_a?(Hash)
      next unless item["perceived_price_cents"].to_s == "0"

      item["permalink"].presence
    end.uniq
  rescue Rack::QueryParser::InvalidParameterError, TypeError, Rack::Multipart::EmptyContentError
    []
  end

  # Charges every free product in the cart one attempt and returns the first one that has
  # gone over its hourly budget, or nil when they are all still under it.
  #
  # Rack::Attack's own counting supports exactly one bucket per request (the value the
  # throttle block returns), which is why this counts by hand: a cart holds several
  # products and all of them have to be charged, or padding the cart with a throwaway
  # product would hide the abused one. `Rack::Attack.cache.count` is the same
  # increment-and-read the gem uses internally, so these buckets expire with the window
  # like every other throttle's do.
  def self.exceeded_free_checkout_permalink(req)
    permalinks = free_checkout_permalinks(req)
    return if permalinks.empty?

    # Count every product BEFORE looking for one over budget — `find` alone would stop
    # incrementing at the first offender and leave the rest of the cart uncharged.
    counts = permalinks.map do |permalink|
      [permalink, cache.count("#{CHECKOUT_FREE_PRODUCT_THROTTLE}:#{permalink}", CHECKOUT_FREE_PRODUCT_PERIOD)]
    end

    counts.find { |_permalink, count| count > CHECKOUT_FREE_PRODUCT_HOURLY_LIMIT }&.first
  end

  # `limit: 0` because the budget is already enforced by
  # `exceeded_free_checkout_permalink` above: the block returns a value only for a
  # request that is already over, and any non-nil discriminator against a limit of 0
  # blocks. This registered throttle exists to turn that decision into Rack::Attack's
  # normal 429 response and instrumentation. Its own counter is namespaced separately
  # (`/exceeded`) so it cannot collide with the per-product buckets counted by hand.
  throttle("#{CHECKOUT_FREE_PRODUCT_THROTTLE}/exceeded", limit: 0, period: CHECKOUT_FREE_PRODUCT_PERIOD) do |req|
    Rack::Attack.exceeded_free_checkout_permalink(req)
  end

  # Help Center contact form. Each submission sends an email into the support
  # inbox, so without a limit a single IP could flood support (and burn email
  # reputation). Real users send one or two messages; `max_level: 1` skips the
  # exponential-backoff tiers, which with a 1-minute base period would derive
  # limits stricter than the base and block legitimate retries. The route is a
  # Rails `resource`, so it accepts any format suffix (`/help/contact.xml`,
  # `/help/contact.txt`, ...) — match by regex like the OAuth device-flow
  # throttles below so no suffix variant bypasses the limit, and key on the IP
  # alone so every variant shares one counter instead of getting its own budget.
  throttle_with_exponential_backoff(name: "help_center_contact/ip", requests: 3, period: 60.seconds, max_level: 1) do |req|
    req.remote_ip if req.path.match?(%r{\A/help/contact(?:\.[^/]+)?\z}) && req.post?
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

  # Media uploads: each POST can make the server synchronously download up to 10 MB from a
  # remote URL (CreatePublicMediaService), so this is one of the most expensive requests in the
  # v2 API — an unthrottled loop would tie up workers and bandwidth. 20 uploads / 10 minutes is
  # plenty for a creator (or the store agent) building a page, and useless for abuse. Keyed by
  # OAuth token (falling back to IP-keyed throttle for tokenless probes) so rotating IPs doesn't
  # bypass it. Both `/api/v2/media` (gumroad.com) and `/v2/media` (api.gumroad.com) prefixes are
  # matched, mirroring the products/custom_html throttles above.
  #
  # `max_level: 1` skips the exponential-backoff tiers: with a 10-minute base period the derived
  # rpm is 2, so the level-2 tier would allow only 4 requests per 64 seconds — stricter than the
  # base limit and it would block a legitimate burst of uploads (same trap the walks throttles
  # above document). The base 20/10min limit already caps the damage.
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
