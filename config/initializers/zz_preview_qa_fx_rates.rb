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
# can never run in production (production runs live keys).
Rails.application.config.after_initialize do
  next unless Stripe.api_key.to_s.start_with?("sk_test_")

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
