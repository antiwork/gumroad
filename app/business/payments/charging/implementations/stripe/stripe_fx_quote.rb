# frozen_string_literal: true

class StripeFxQuote
  include StripeErrorHandler

  # Stripe can settle in a currency the connected account enabled through multi-currency
  # settlement rather than the requested one, and the stored merchant_account.currency can
  # be stale — so Stripe's own answer is the only trustworthy settlement-currency source.
  # Stripe signals the mismatch two ways: by returning a quote whose to_currency differs
  # from the requested one, or by rejecting the quote creation outright with an
  # InvalidRequestError whose message matches SETTLEMENT_MISMATCH_MESSAGE. Both are mapped
  # to this error so callers can treat them as one expected "fall back to USD" condition.
  SettlementCurrencyMismatch = Class.new(StandardError)

  # Stripe's request-time rejection when the account's settlement currency differs from
  # the requested to_currency, e.g.:
  #   The FX Quote's to_currency: "usd" must match the payment intent's settlement currency: "cad".
  SETTLEMENT_MISMATCH_MESSAGE = /must match the payment intent's settlement currency/i

  API_VERSION = "2025-07-30.preview"
  LOCK_DURATION = "hour"
  OPEN_TIMEOUT_SECONDS = 2
  READ_TIMEOUT_SECONDS = 5
  WRITE_TIMEOUT_SECONDS = 2

  Quote = Struct.new(:id, :expires_at, :fx_rate, keyword_init: true)

  def self.create(to_currency:, from_currency:, stripe_account_id:)
    new.create(to_currency:, from_currency:, stripe_account_id:)
  end

  def create(to_currency:, from_currency:, stripe_account_id:)
    stripe_options = { stripe_version: API_VERSION, client: stripe_client }
    stripe_options[:stripe_account] = stripe_account_id if stripe_account_id.present?

    response = with_stripe_error_handler do
      # Stripe Ruby 12.5.0 does not wrap the preview FX Quotes endpoint yet.
      Stripe.raw_request(
        :post,
        "/v1/fx_quotes",
        {
          to_currency: to_currency.to_s.downcase,
          from_currencies: [from_currency.to_s.downcase],
          lock_duration: LOCK_DURATION,
          usage: { type: "payment" },
        },
        stripe_options
      )
    end

    build_quote(response.data, from_currency: from_currency.to_s.downcase, to_currency: to_currency.to_s.downcase)
  rescue ChargeProcessorInvalidRequestError => e
    # Some connected accounts settle in a non-USD currency (multi-currency settlement),
    # and Stripe rejects the quote request itself instead of returning a mismatched quote.
    # That's the same expected condition build_quote catches, not a code defect — surface
    # it as SettlementCurrencyMismatch so callers fall back to the canonical USD path
    # without paging anyone.
    raise SettlementCurrencyMismatch, e.message if e.message.to_s.match?(SETTLEMENT_MISMATCH_MESSAGE)
    raise
  end

  private
    def stripe_client
      Stripe::StripeClient.new(
        open_timeout: OPEN_TIMEOUT_SECONDS,
        read_timeout: READ_TIMEOUT_SECONDS,
        write_timeout: WRITE_TIMEOUT_SECONDS
      )
    end

    def build_quote(data, from_currency:, to_currency:)
      actual_to_currency = (data[:to_currency] || data["to_currency"]).to_s.downcase
      if actual_to_currency != to_currency
        raise SettlementCurrencyMismatch,
              "FX quote settles in #{actual_to_currency.presence || "unknown"}, expected #{to_currency}"
      end

      Quote.new(
        id: data.fetch(:id),
        expires_at: parsed_expires_at(data.fetch(:lock_expires_at)),
        fx_rate: parsed_rate(data.fetch(:rates), from_currency:)
      )
    end

    def parsed_expires_at(expires_at)
      return Time.zone.at(expires_at) if expires_at.is_a?(Numeric)

      Time.zone.parse(expires_at.to_s)
    end

    def parsed_rate(rates, from_currency:)
      rate_data = rates.fetch(from_currency.to_sym) { rates.fetch(from_currency) }
      rate = rate_data.is_a?(Hash) ? rate_data.fetch(:exchange_rate) { rate_data.fetch("exchange_rate") } : rate_data
      BigDecimal(rate.to_s)
    end
end
