# frozen_string_literal: true

module StripeCurrencyBalancesReport
  extend CurrencyHelper

  def self.stripe_currency_balances_report
    currency_balances = {}

    stripe_balance = Stripe::Balance.retrieve
    stripe_balance.available.sort_by { _1["currency"]  }.each do |balance|
      currency_balances[balance["currency"]] = balance["amount"]
    end

    stripe_balance.connect_reserved.sort_by { _1["currency"]  }.each do |balance|
      currency_balances[balance["currency"]] += balance["amount"] if currency_balances[balance["currency"]].abs != balance["amount"].abs
    end

    CsvSafe.generate do |csv|
      csv << %w(Currency Balance)
      currency_balances.each do |currency, balance|
        csv << [currency, is_currency_type_single_unit?(currency) ? balance : (balance / 100.0).round(2)]
      end
    end
  end
end
