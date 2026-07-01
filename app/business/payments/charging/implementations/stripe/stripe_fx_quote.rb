# frozen_string_literal: true

class StripeFxQuote
  include StripeErrorHandler

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

    build_quote(response.data, from_currency: from_currency.to_s.downcase)
  end

  private
    def stripe_client
      Stripe::StripeClient.new(
        open_timeout: OPEN_TIMEOUT_SECONDS,
        read_timeout: READ_TIMEOUT_SECONDS,
        write_timeout: WRITE_TIMEOUT_SECONDS
      )
    end

    def build_quote(data, from_currency:)
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
