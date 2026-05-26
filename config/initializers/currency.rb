# frozen_string_literal: true

CURRENCY_CHOICES = HashWithIndifferentAccess.new(
  JSON.load_file(Rails.root.join("config/currencies.json").to_s)["currencies"]
)
BACKUP_CURRENCY_RATES_PATH = Rails.root.join("lib/currency/backup_rates.json").to_s
STRIPE_FX_QUOTES_API_VERSION = "2025-07-30.preview"
STRIPE_FX_SUPPORTED_CURRENCIES = %w[
  AED AUD AWG BBD BHD BMD BSD CAD CHF DKK EUR GBP HKD IDR INR
  JOD JPY KWD MYR NZD OMR PAB RON SAR SEK SGD THB USD XCD YER
  AFN ALL AMD ANG AOA AZN BAM BDT BIF BND BOB BRL BWP BZD CLP
  CNY COP CRC CVE CZK DJF DOP DZD FKP GEL GIP GMD GNF GTQ GYD
  HNL HTG HUF ILS ISK JMD KES KGS KHR KRW KYD KZT LKR LRD MAD
  MDL MGA MKD MNT MOP MUR MVR MXN MZN NAD NOK NPR PEN PHP PKR
  PLN PYG QAR RSD RWF SHP STD TJS TND TRY TTD TWD TZS UAH UGX
  UYU UZS VND XAF XOF XPF ZAR ZMW
].freeze
STRIPE_FX_CURRENCY_CHOICES = (CURRENCY_CHOICES.keys.map { _1.to_s.upcase } & STRIPE_FX_SUPPORTED_CURRENCIES).freeze

unless defined?(Stripe::FxQuote)
  module Stripe
    class FxQuote
      def self.create(params = {}, opts = {})
        response = Stripe.raw_request(
          :post,
          "/v1/fx_quotes",
          params,
          { stripe_version: ::STRIPE_FX_QUOTES_API_VERSION }.merge(opts)
        )

        Stripe.deserialize(response.http_body)
      end
    end
  end
end
