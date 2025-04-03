# frozen_string_literal: true

class UpdateCurrenciesWorker
  include Sidekiq::Job
  include CurrencyHelper
  sidekiq_options retry: 5, queue: :default

  def perform
    rates = JSON.parse(URI.open(CURRENCY_SOURCE).read)["rates"]

    rates.each do |currency, rate|
      currency_namespace.set(currency.to_s, rate)
    end
  end
end
