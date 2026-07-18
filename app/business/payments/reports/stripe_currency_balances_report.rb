# frozen_string_literal: true

# Snapshots the Gumroad platform Stripe account's balance, broken out per currency, for
# the monthly close email (AccountingMailer.stripe_currency_balances_report).
#
# A currency's cash position is the sum of three Stripe balance buckets: available (ready
# to pay out), pending (settling), and connect_reserved (held by Gumroad as the platform
# against connected-account obligations — still Gumroad's cash). The CSV keeps the
# per-bucket split visible so finance can see the composition, and adds a USD-converted
# column (from the app's hourly-cached exchange rates) so non-USD residuals can be
# reconciled without a separate FX lookup.
module StripeCurrencyBalancesReport
  extend CurrencyHelper

  BUCKETS = %i[available pending connect_reserved].freeze

  def self.stripe_currency_balances_report
    # to_hash gives plain nested hashes (symbol keys) and, unlike calling the accessor,
    # tolerates a bucket being entirely absent from the API response.
    stripe_balance = Stripe::Balance.retrieve.to_hash

    currency_balances = Hash.new { |hash, currency| hash[currency] = BUCKETS.index_with { 0 } }
    BUCKETS.each do |bucket|
      Array(stripe_balance[bucket]).each do |balance|
        currency_balances[balance[:currency]][bucket] += balance[:amount]
      end
    end

    CsvSafe.generate do |csv|
      csv << ["Currency", "Available", "Pending", "Connect reserved", "Total", "USD equivalent"]
      currency_balances.sort.each do |currency, buckets|
        total = buckets.values.sum
        csv << [
          currency,
          *buckets.values.map { in_major_units(currency, _1) },
          in_major_units(currency, total),
          usd_equivalent(currency, total),
        ]
      end
    end
  end

  # Stripe reports amounts in the currency's minor unit; single-unit currencies (JPY,
  # KRW, ...) have no minor unit, so their amounts are already whole.
  def self.in_major_units(currency, amount)
    is_currency_type_single_unit?(currency) ? amount : (amount / 100.0).round(2)
  end

  # Converts a minor-unit amount to whole US dollars using the hourly-cached rate (safe
  # to read here — no inline rate fetch). Left blank when no rate is cached for the
  # currency so a missing rate is visible rather than silently reported as zero.
  def self.usd_equivalent(currency, amount)
    rate = cached_usd_rate(currency)
    return nil if rate.nil?

    major_units = is_currency_type_single_unit?(currency) ? amount : amount / 100.0
    (major_units / rate).round(2)
  end
end
