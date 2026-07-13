# frozen_string_literal: true

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
class PreviewQaDebugMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless Stripe.api_key.to_s.start_with?("sk_test_")

    spoof = env["HTTP_X_QA_SPOOF_IP"]
    if spoof.present? && spoof.match?(/\A[0-9a-fA-F.:]+\z/)
      env["HTTP_CF_CONNECTING_IP"] = spoof
      env["HTTP_X_FORWARDED_FOR"] = spoof
      env["REMOTE_ADDR"] = spoof
    end

    req = Rack::Request.new(env)
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
end
Rails.application.config.middleware.insert_before(0, PreviewQaDebugMiddleware) if Rails.env.staging? || Rails.env.development?
