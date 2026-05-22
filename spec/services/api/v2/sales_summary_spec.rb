# frozen_string_literal: true

require "spec_helper"

describe Api::V2::SalesSummary do
  describe "#as_json" do
    it "returns totals for the requested date range" do
      seller = create(:user, timezone: "UTC")
      product = create(:product, user: seller, price_cents: 10_00)
      create(:purchase, link: product, price_cents: 10_00, created_at: Time.utc(2026, 1, 1, 12))
      create(:purchase, link: product, price_cents: 20_00, created_at: Time.utc(2026, 1, 2, 12))
      partially_refunded_purchase = create(:purchase, link: product, price_cents: 30_00, created_at: Time.utc(2026, 1, 3, 12))
      partially_refunded_purchase.refund_partial_purchase!(5_00, seller.id)
      create(:refunded_purchase, link: product, price_cents: 40_00, created_at: Time.utc(2026, 1, 3, 12))
      create(:purchase, link: product, price_cents: 50_00, created_at: Time.utc(2026, 2, 1, 12))
      create(:failed_purchase, link: product, price_cents: 60_00, created_at: Time.utc(2026, 1, 2, 12))
      create(:purchase, :gift_receiver, link: product, price_cents: 70_00, created_at: Time.utc(2026, 1, 2, 12))
      create(:purchase, price_cents: 80_00, created_at: Time.utc(2026, 1, 2, 12))
      index_model_records(Purchase)

      result = described_class.new(seller:, from: Date.new(2026, 1, 1), to: Date.new(2026, 1, 31)).as_json

      expect(result).to eq(
        gross_cents: 100_00,
        net_cents: 55_00,
        units: 4,
        refunded_cents: 45_00,
        refunded_units: 2,
        currency: "usd",
        from: "2026-01-01",
        to: "2026-01-31",
      )
    end

    it "returns product breakdowns sorted by gross sales" do
      seller = create(:user, timezone: "UTC")
      product = create(:product, user: seller, name: "Small product", price_cents: 10_00)
      larger_product = create(:product, user: seller, name: "Large product", price_cents: 20_00)
      create(:purchase, link: product, price_cents: 10_00, created_at: Time.utc(2026, 1, 1, 12))
      create(:purchase, link: larger_product, price_cents: 20_00, created_at: Time.utc(2026, 1, 2, 12))
      partially_refunded_purchase = create(:purchase, link: larger_product, price_cents: 30_00, created_at: Time.utc(2026, 1, 3, 12))
      partially_refunded_purchase.refund_partial_purchase!(5_00, seller.id)
      index_model_records(Purchase)

      result = described_class.new(seller:, from: Date.new(2026, 1, 1), to: Date.new(2026, 1, 31), group_by: "product").as_json

      expect(result[:breakdown]).to eq([
                                         {
                                           key: larger_product.external_id,
                                           label: "Large product",
                                           gross_cents: 50_00,
                                           net_cents: 45_00,
                                           units: 2,
                                           refunded_cents: 5_00,
                                           refunded_units: 1,
                                         },
                                         {
                                           key: product.external_id,
                                           label: "Small product",
                                           gross_cents: 10_00,
                                           net_cents: 10_00,
                                           units: 1,
                                           refunded_cents: 0,
                                           refunded_units: 0,
                                         }
                                       ])
    end

    it "paginates breakdown buckets" do
      stub_const("#{described_class}::ES_MAX_BUCKET_SIZE", 2)
      seller = create(:user, timezone: "UTC")
      products = create_list(:product, 3, user: seller, price_cents: 10_00)
      products.each do |product|
        create(:purchase, link: product, price_cents: 10_00, created_at: Time.utc(2026, 1, 1, 12))
      end
      index_model_records(Purchase)

      expect(Purchase).to receive(:search).exactly(3).times.and_call_original

      result = described_class.new(seller:, from: Date.new(2026, 1, 1), to: Date.new(2026, 1, 31), group_by: "product").as_json

      expect(result[:breakdown].map { _1[:key] }).to match_array(products.map(&:external_id))
    end

    it "groups date breakdowns in the seller's timezone" do
      seller = create(:user, timezone: "Pacific Time (US & Canada)")
      product = create(:product, user: seller, price_cents: 10_00)
      create(:purchase, link: product, price_cents: 10_00, created_at: Time.utc(2026, 5, 21, 6, 30))
      create(:purchase, link: product, price_cents: 20_00, created_at: Time.utc(2026, 5, 21, 8, 0))
      index_model_records(Purchase)

      result = described_class.new(seller:, from: Date.new(2026, 5, 20), to: Date.new(2026, 5, 21), group_by: "day").as_json

      expect(result[:breakdown]).to eq([
                                         {
                                           key: "2026-05-20",
                                           label: "2026-05-20",
                                           gross_cents: 10_00,
                                           net_cents: 10_00,
                                           units: 1,
                                           refunded_cents: 0,
                                           refunded_units: 0,
                                         },
                                         {
                                           key: "2026-05-21",
                                           label: "2026-05-21",
                                           gross_cents: 20_00,
                                           net_cents: 20_00,
                                           units: 1,
                                           refunded_cents: 0,
                                           refunded_units: 0,
                                         }
                                       ])
    end

    it "groups monthly breakdowns" do
      seller = create(:user, timezone: "UTC")
      product = create(:product, user: seller, price_cents: 10_00)
      create(:purchase, link: product, price_cents: 10_00, created_at: Time.utc(2026, 1, 31, 12))
      create(:purchase, link: product, price_cents: 20_00, created_at: Time.utc(2026, 2, 1, 12))
      index_model_records(Purchase)

      result = described_class.new(seller:, from: Date.new(2026, 1, 1), to: Date.new(2026, 2, 28), group_by: "month").as_json

      expect(result[:breakdown].pluck(:key)).to eq(["2026-01", "2026-02"])
    end

    it "groups weekly breakdowns" do
      seller = create(:user, timezone: "UTC")
      product = create(:product, user: seller, price_cents: 10_00)
      create(:purchase, link: product, price_cents: 10_00, created_at: Time.utc(2026, 1, 7, 12))
      create(:purchase, link: product, price_cents: 20_00, created_at: Time.utc(2026, 1, 12, 12))
      index_model_records(Purchase)

      result = described_class.new(seller:, from: Date.new(2026, 1, 1), to: Date.new(2026, 1, 31), group_by: "week").as_json

      expect(result[:breakdown].pluck(:key)).to eq(["2026-01-05", "2026-01-12"])
    end
  end
end
