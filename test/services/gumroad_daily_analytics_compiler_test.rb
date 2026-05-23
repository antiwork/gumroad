# frozen_string_literal: true

require "test_helper"

class GumroadDailyAnalyticsCompilerTest < ActiveSupport::TestCase
  self.described_class = GumroadDailyAnalyticsCompiler



  context_ GumroadDailyAnalyticsCompiler do
  context_ ".compile_gumroad_price_cents" do
  test "aggregates data for the dates provided" do
        create :purchase, created_at: Time.utc(2023, 1, 4)
        create :purchase, created_at: Time.utc(2023, 1, 5)
        create :purchase, created_at: Time.utc(2023, 1, 6)
        create :purchase, created_at: Time.utc(2023, 1, 7)
        create :purchase, created_at: Time.utc(2023, 1, 8)

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 7)
        value = GumroadDailyAnalyticsCompiler.compile_gumroad_price_cents(between: range)

        expect(value).to eq(300)
      end

  test "aggregates purchase amounts" do
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 200
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 300

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
        value = GumroadDailyAnalyticsCompiler.compile_gumroad_price_cents(between: range)

        expect(value).to eq(600)
      end

  test "ignores unsuccessful purchases" do
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 200, purchase_state: "failed"
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 300, purchase_state: "in_progress"

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
        value = GumroadDailyAnalyticsCompiler.compile_gumroad_price_cents(between: range)

        expect(value).to eq(100)
      end

  test "ignores refunded purchases" do
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 200, stripe_refunded: true
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 300

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
        value = GumroadDailyAnalyticsCompiler.compile_gumroad_price_cents(between: range)

        expect(value).to eq(400)
      end
    end

  context_ ".compile_gumroad_fee_cents" do
  test "aggregates data for the dates provided" do
        create :purchase, created_at: Time.utc(2023, 1, 4)
        create :purchase, created_at: Time.utc(2023, 1, 5)
        create :purchase, created_at: Time.utc(2023, 1, 6)
        create :purchase, created_at: Time.utc(2023, 1, 7)
        create :purchase, created_at: Time.utc(2023, 1, 8)
        Purchase.update_all("fee_cents = price_cents / 10") # Force fee to be 10% of purchase amount

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 7)
        value = GumroadDailyAnalyticsCompiler.compile_gumroad_fee_cents(between: range)

        expect(value).to eq(30)
      end

  test "aggregates both purchase fees and service charges" do
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100 # fee_cents: 10
        create :service_charge, created_at: Time.utc(2023, 1, 5), charge_cents: 20
        Purchase.update_all("fee_cents = price_cents / 10") # Force fee to be 10% of purchase amount

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
        value = GumroadDailyAnalyticsCompiler.compile_gumroad_fee_cents(between: range)

        expect(value).to eq(30)
      end

  context_ "purchase fees" do
  test "aggregates purchases" do
          create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100 # fee_cents: 10
          create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 200 # fee_cents: 20
          create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 300 # fee_cents: 30
          Purchase.update_all("fee_cents = price_cents / 10") # Force fee to be 10% of purchase amount

          range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
          value = GumroadDailyAnalyticsCompiler.compile_gumroad_fee_cents(between: range)

          expect(value).to eq(60)
        end

  test "ignores unsuccessful purchases" do
          create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100 # fee_cents: 10
          create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 200, purchase_state: "failed" # fee_cents: 20
          create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 300, purchase_state: "in_progress" # fee_cents: 30
          Purchase.update_all("fee_cents = price_cents / 10") # Force fee to be 10% of purchase amount

          range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
          value = GumroadDailyAnalyticsCompiler.compile_gumroad_fee_cents(between: range)

          expect(value).to eq(10)
        end

  test "ignores refunded purchases" do
          create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100 # fee_cents: 10
          create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 200, stripe_refunded: true # fee_cents: 20
          create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 300 # fee_cents: 30
          Purchase.update_all("fee_cents = price_cents / 10") # Force fee to be 10% of purchase amount

          range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
          value = GumroadDailyAnalyticsCompiler.compile_gumroad_fee_cents(between: range)

          expect(value).to eq(40)
        end
      end

  context_ "service charges" do
  test "aggregates service charges" do
          create :service_charge, created_at: Time.utc(2023, 1, 5), charge_cents: 10
          create :service_charge, created_at: Time.utc(2023, 1, 5), charge_cents: 20
          create :service_charge, created_at: Time.utc(2023, 1, 5), charge_cents: 30

          range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
          value = GumroadDailyAnalyticsCompiler.compile_gumroad_fee_cents(between: range)

          expect(value).to eq(60)
        end

  test "ignores failed service charges" do
          create :service_charge, created_at: Time.utc(2023, 1, 5), charge_cents: 10
          create :service_charge, created_at: Time.utc(2023, 1, 5), charge_cents: 20, state: "failed"
          create :service_charge, created_at: Time.utc(2023, 1, 5), charge_cents: 30

          range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
          value = GumroadDailyAnalyticsCompiler.compile_gumroad_fee_cents(between: range)

          expect(value).to eq(40)
        end

  test "ignores refunded service charges" do
          create :service_charge, created_at: Time.utc(2023, 1, 5), charge_cents: 10
          create :service_charge, created_at: Time.utc(2023, 1, 5), charge_cents: 20, charge_processor_refunded: 13
          create :service_charge, created_at: Time.utc(2023, 1, 5), charge_cents: 30

          range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
          value = GumroadDailyAnalyticsCompiler.compile_gumroad_fee_cents(between: range)

          expect(value).to eq(40)
        end
      end
    end

  context_ ".compile_creators_with_sales" do
  test "aggregates data for the dates provided" do
        create :purchase, created_at: Time.utc(2023, 1, 4)
        create :purchase, created_at: Time.utc(2023, 1, 5)
        create :purchase, created_at: Time.utc(2023, 1, 6)
        create :purchase, created_at: Time.utc(2023, 1, 7)
        create :purchase, created_at: Time.utc(2023, 1, 8)

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 7)
        value = GumroadDailyAnalyticsCompiler.compile_creators_with_sales(between: range)

        expect(value).to eq(3)
      end

  test "aggregates creators with at least a 1 dollar sale" do
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 99
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 150

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
        value = GumroadDailyAnalyticsCompiler.compile_creators_with_sales(between: range)

        expect(value).to eq(2)
      end

  test "does not count the same creator twice" do
        product = create :product
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100, link: product
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 150, link: product

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
        value = GumroadDailyAnalyticsCompiler.compile_creators_with_sales(between: range)

        expect(value).to eq(1)
      end

  test "ignores suspended creators" do
        purchase_1 = create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100
        purchase_2 = create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100
        purchase_1.seller.update!(user_risk_state: "suspended_for_fraud")
        purchase_2.seller.update!(user_risk_state: "suspended_for_tos_violation")

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
        value = GumroadDailyAnalyticsCompiler.compile_creators_with_sales(between: range)

        expect(value).to eq(0)
      end

  test "ignores unsuccessful purchases" do
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 200, purchase_state: "failed"
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 300, purchase_state: "in_progress"

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
        value = GumroadDailyAnalyticsCompiler.compile_creators_with_sales(between: range)

        expect(value).to eq(1)
      end

  test "ignores refunded purchases" do
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 200, stripe_refunded: true
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 300

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
        value = GumroadDailyAnalyticsCompiler.compile_creators_with_sales(between: range)

        expect(value).to eq(2)
      end
    end

  context_ ".compile_gumroad_discover_price_cents" do
  test "aggregates data for the dates provided" do
        create :purchase, created_at: Time.utc(2023, 1, 4), was_product_recommended: true
        create :purchase, created_at: Time.utc(2023, 1, 5), was_product_recommended: true
        create :purchase, created_at: Time.utc(2023, 1, 6), was_product_recommended: true
        create :purchase, created_at: Time.utc(2023, 1, 7), was_product_recommended: true
        create :purchase, created_at: Time.utc(2023, 1, 8), was_product_recommended: true

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 7)
        value = GumroadDailyAnalyticsCompiler.compile_gumroad_discover_price_cents(between: range)

        expect(value).to eq(300)
      end

  test "aggregates discovery purchase amounts" do
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100, was_product_recommended: true
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 200
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 300, was_product_recommended: true

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
        value = GumroadDailyAnalyticsCompiler.compile_gumroad_discover_price_cents(between: range)

        expect(value).to eq(400)
      end

  test "ignores unsuccessful purchases" do
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100, was_product_recommended: true
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 200, was_product_recommended: true, purchase_state: "failed"
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 300, was_product_recommended: true, purchase_state: "in_progress"

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
        value = GumroadDailyAnalyticsCompiler.compile_gumroad_discover_price_cents(between: range)

        expect(value).to eq(100)
      end

  test "ignores refunded purchases" do
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 100, was_product_recommended: true
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 200, was_product_recommended: true, stripe_refunded: true
        create :purchase, created_at: Time.utc(2023, 1, 5), price_cents: 300, was_product_recommended: true

        range = Time.utc(2023, 1, 5)..Time.utc(2023, 1, 5)
        value = GumroadDailyAnalyticsCompiler.compile_gumroad_discover_price_cents(between: range)

        expect(value).to eq(400)
      end
    end
  end
end
