# frozen_string_literal: true

class GumroadDailyAnalytic < ApplicationRecord
  validates :period_ended_at, :gumroad_price_cents, :gumroad_fee_cents, :creators_with_sales, :gumroad_discover_price_cents, presence: true

  def self.import(date)
    date_range = date.all_day
    analytic = GumroadDailyAnalytic.find_or_initialize_by(period_ended_at: date_range.last)

    analytic.gumroad_price_cents = GumroadDailyAnalyticsCompiler.compile_gumroad_price_cents(between: date_range)
    analytic.gumroad_fee_cents = GumroadDailyAnalyticsCompiler.compile_gumroad_fee_cents(between: date_range)
    analytic.creators_with_sales = GumroadDailyAnalyticsCompiler.compile_creators_with_sales(between: date_range)
    analytic.gumroad_discover_price_cents = GumroadDailyAnalyticsCompiler.compile_gumroad_discover_price_cents(between: date_range)

    analytic.save!
  end
end
