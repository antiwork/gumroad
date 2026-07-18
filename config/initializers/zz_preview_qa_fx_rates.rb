# frozen_string_literal: true

# TEMP (preview QA only — revert only AFTER QA sign-off, before merge):
# Fresh per-PR preview apps have an empty Redis, and the buyer-local-currency display
# layer only reads USD rates from the hourly UpdateCurrenciesWorker cache
# (CurrencyHelper#cached_usd_rate — no inline fetch on the render path). Without rates,
# buyer_currency_display_props silently falls back to USD display and the buyer-currency
# presentment lane under QA on antiwork/gumroad#5781 never activates.
#
# Seeds a few plausible USD-based rates at boot so QA testers (and the scripted QA run)
# can exercise the presentment-mounted Payment Element. Gated to Stripe test mode so it
# can never run in production (production runs live keys), and — like the request
# middleware below — scoped to per-PR preview apps (ENV["BRANCH_DEPLOYMENT"], the same
# boot-time flag the rest of the preview tooling keys off) plus local development. The
# shared staging site also runs test keys but shares one Redis, so seeding there would
# overwrite the real :currencies cache for everyone until UpdateCurrenciesWorker refreshes it.
Rails.application.config.after_initialize do
  next unless Stripe.api_key.to_s.start_with?("sk_test_")
  next unless Rails.env.development? || (Rails.env.staging? && ENV["BRANCH_DEPLOYMENT"] == "true")

  begin
    namespace = Redis::Namespace.new(:currencies, redis: $redis)
    {
      "CAD" => "1.37",
      "EUR" => "0.92",
      "GBP" => "0.79",
      "AUD" => "1.51",
    }.each do |currency, rate|
      namespace.set(currency, rate) if namespace.get(currency).blank?
    end
    Rails.logger.info("[preview-qa] seeded buyer-currency FX display rates")
  rescue StandardError => e
    Rails.logger.warn("[preview-qa] FX rate seed skipped: #{e.class} #{e.message}")
  end
end

# TEMP QA debug endpoint (test-mode only): tells apart a GeoIP miss from a missing FX
# rate when the buyer-local-currency display falls back to USD on the preview.
# GET /qa/preview_debug returns what the display chain sees for the requesting IP.
#
# Also honors an X-QA-Spoof-IP header (test-mode only): the preview's load balancer
# overwrites CF-Connecting-IP/X-Forwarded-For with the real client IP, so the documented
# header-spoof recipe for simulating buyer geography cannot reach GeoIP here. This
# middleware runs before ActionDispatch::RemoteIp and rewrites the forwarding headers
# from the custom header (which the LB passes through untouched), restoring the ability
# to QA non-US buyer flows. Production runs live Stripe keys, so this can never activate there.
#
# Scope: the spoof and the debug endpoint only respond on per-PR preview app hosts
# (*.apps.staging.gumroad.org) and local development. The shared staging site also runs
# test Stripe keys, so without this host check anyone could rewrite their apparent IP
# there — the QA helper is only needed on the throwaway preview apps.
class PreviewQaDebugMiddleware
  PREVIEW_HOST_SUFFIX = ".apps.staging.gumroad.org"

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless Stripe.api_key.to_s.start_with?("sk_test_")
    return @app.call(env) unless preview_or_development_host?(env)

    req = Rack::Request.new(env)

    # Cookie mode for human testers on phones/tablets, where sending a custom header is
    # impractical: GET /qa/spoof?ip=<addr> stores the spoof IP in a cookie and every
    # later request behaves as if it came from that IP; /qa/spoof?off=1 clears it.
    # Same test-key + preview-host gates as the header mode, so production and shared
    # staging are untouched.
    if req.path == "/qa/spoof"
      headers = { "Content-Type" => "text/html" }
      if req.params["off"].present?
        Rack::Utils.delete_cookie_header!(headers, "qa_spoof_ip", { path: "/" })
        return [200, headers, ["<html><body><h2>QA IP spoof cleared.</h2></body></html>"]]
      end
      ip_param = req.params["ip"].to_s
      unless ip_param.match?(/\A[0-9a-fA-F.:]+\z/)
        return [400, headers, ["<html><body><h2>Pass ?ip=&lt;address&gt; or ?off=1</h2></body></html>"]]
      end
      Rack::Utils.set_cookie_header!(headers, "qa_spoof_ip", { value: ip_param, path: "/" })
      return [200, headers, ["<html><body><h2>QA IP spoof set to #{Rack::Utils.escape_html(ip_param)}.</h2><p>Every request from this browser now appears to come from that IP. <a href=\"/qa/preview_debug\">Verify</a> &middot; <a href=\"/qa/spoof?off=1\">Turn off</a></p></body></html>"]]
    end

    spoof = env["HTTP_X_QA_SPOOF_IP"].presence || req.cookies["qa_spoof_ip"]
    if spoof.present? && spoof.match?(/\A[0-9a-fA-F.:]+\z/)
      env["HTTP_CF_CONNECTING_IP"] = spoof
      env["HTTP_X_FORWARDED_FOR"] = spoof
      env["REMOTE_ADDR"] = spoof
    end

    return @app.call(env) unless req.path == "/qa/preview_debug"

    helper = Class.new { include CurrencyHelper }.new
    ip = req.ip
    geo = begin
      GeoIp.lookup(ip)
    rescue StandardError => e
      { error: "#{e.class}: #{e.message}" }
    end
    body = {
      remote_ip: ip,
      cf_connecting_ip: env["HTTP_CF_CONNECTING_IP"],
      x_forwarded_for: env["HTTP_X_FORWARDED_FOR"],
      geo_country_code: geo.respond_to?(:country_code) ? geo.country_code : geo,
      buyer_currency_for_ip: helper.buyer_currency_for_ip(ip),
      cached_cad_rate: helper.cached_usd_rate("cad")&.to_s,
      cached_eur_rate: helper.cached_usd_rate("eur")&.to_s,
    }
    [200, { "Content-Type" => "application/json" }, [body.to_json]]
  end

  private
    # Rack::Request#host strips the port and handles a missing Host header.
    def preview_or_development_host?(env)
      return true if Rails.env.development?

      Rack::Request.new(env).host.to_s.end_with?(PREVIEW_HOST_SUFFIX)
    end
end
Rails.application.config.middleware.insert_before(0, PreviewQaDebugMiddleware) if Rails.env.staging? || Rails.env.development?
