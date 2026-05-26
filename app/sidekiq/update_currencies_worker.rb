# frozen_string_literal: true

class UpdateCurrenciesWorker
  include Sidekiq::Job
  include CurrencyHelper
  sidekiq_options retry: 5, queue: :default

  def perform
    rates_for_cache.each do |currency, rate|
      currency_namespace.set(currency.to_s, rate)
    end
  end

  private
    def rates_for_cache
      return backup_rates_for_currency_choices unless use_stripe_fx_quotes?

      backup_rates_for_currency_choices.merge(stripe_fx_rates(currency_choice_codes))
    rescue Stripe::StripeError => e
      notify_stripe_fx_quote_error(e, currencies: stripe_fx_currency_choice_codes)
      backup_rates_for_currency_choices
    end

    def backup_rates_for_currency_choices
      backup_currency_rates.slice(*currency_choice_codes)
    end

    def currency_choice_codes
      CURRENCY_CHOICES.keys.map { _1.to_s.upcase }
    end

    def stripe_fx_currency_choice_codes
      (currency_choice_codes & STRIPE_FX_CURRENCY_CHOICES) - ["USD"]
    end
end
