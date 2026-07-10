# frozen_string_literal: true

# QA-ONLY seeding for per-PR preview apps — this file lives on the throwaway
# [DO NOT MERGE] preview branch (PR #5737) and must never reach main.
#
# Purchasing-power-parity discounts read per-country factors from Redis
# (the "ppp" namespace), which production populates via a weekly Sunday cron
# (UpdatePurchasingPowerParityFactorsWorker). A freshly booted preview app has
# an empty Redis, so every country's factor is 1 and no PPP discount ever
# renders — which blocks the manual PPP checkout QA for antiwork/gumroad#5701.
#
# Seed a few representative country factors at boot so a buyer arriving from
# one of these countries sees a real PPP-discounted checkout. Guarded to
# Stripe test mode: preview/staging apps run sk_test_ keys, production runs
# live keys, so this can never execute in production.
Rails.application.config.after_initialize do
  next unless Stripe.api_key.to_s.start_with?("sk_test_")

  service = PurchasingPowerParityService.new
  # US included (0.5) purely so headless QA driven from US egress IPs can exercise
  # PPP-discounted checkouts too — production PPP would never discount US buyers.
  { "ID" => 0.35, "IN" => 0.3, "BR" => 0.45, "PH" => 0.35, "MX" => 0.5, "US" => 0.5 }.each do |country, factor|
    service.set_factor(country, factor)
  end
  Rails.logger.info("[preview-qa] Seeded PPP factors for ID/IN/BR/PH/MX/US")
rescue => e
  Rails.logger.warn("[preview-qa] PPP factor seeding failed: #{e.class}: #{e.message}")
end
