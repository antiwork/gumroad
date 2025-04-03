# frozen_string_literal: true

require "spec_helper"

describe CompileGumroadDailyAnalyticsJob do
  it "compiles analytics for the refresh period" do
    stub_const("CompileGumroadDailyAnalyticsJob::REFRESH_PERIOD", 5.days)
    allow(Date).to receive(:today).and_return(Date.new(2023, 1, 15))

    create :purchase, created_at: Time.utc(2023, 1, 10, 14, 0), price_cents: 3000
    create :purchase, created_at: Time.utc(2023, 1, 10, 14, 30), price_cents: 3000
    create :purchase, created_at: Time.utc(2023, 1, 10, 19, 0), price_cents: 2000, was_product_recommended: true
    create :purchase, created_at: Time.utc(2023, 1, 10, 19, 0), price_cents: 1500, was_product_recommended: true
    create :service_charge, created_at: Time.utc(2023, 1, 10, 20, 0), charge_cents: 25
    create :service_charge, created_at: Time.utc(2023, 1, 10, 21, 0), charge_cents: 25

    create :purchase, created_at: Time.utc(2023, 1, 14, 10, 0), price_cents: 5000
    create :purchase, created_at: Time.utc(2023, 1, 14, 12, 0), price_cents: 10000, was_product_recommended: true
    create :gumroad_daily_analytic, period_ended_at: Time.utc(2023, 1, 14).end_of_day, gumroad_price_cents: 999
    Purchase.all.map { |p| p.update!(fee_cents: p.price_cents / 10) } # Force fee to be 10% of purchase amount

    CompileGumroadDailyAnalyticsJob.new.perform

    analytic_1 = GumroadDailyAnalytic.find_by(period_ended_at: Time.utc(2023, 1, 10).end_of_day)
    analytic_2 = GumroadDailyAnalytic.find_by(period_ended_at: Time.utc(2023, 1, 14).end_of_day)
    expect(GumroadDailyAnalytic.all.size).to eq(6) # The refresh period (5 days) + today = 6 days

    expect(analytic_1.gumroad_price_cents).to eq(9500)
    expect(analytic_1.gumroad_fee_cents).to eq(1000)
    expect(analytic_1.creators_with_sales).to eq(4)
    expect(analytic_1.gumroad_discover_price_cents).to eq(3500)

    expect(analytic_2.gumroad_price_cents).to eq(15000)
    expect(analytic_2.gumroad_fee_cents).to eq(1500)
    expect(analytic_2.creators_with_sales).to eq(2)
    expect(analytic_2.gumroad_discover_price_cents).to eq(10000)
  end
end
