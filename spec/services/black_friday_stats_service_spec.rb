# frozen_string_literal: true

require "spec_helper"

describe BlackFridayStatsService do
  describe ".calculate_stats" do
    let(:code) { SearchProducts::BLACK_FRIDAY_CODE }

    before do
      allow_any_instance_of(OfferCode).to receive(:reindex_associated_products)
    end

    it "returns zeros when no Black Friday offer codes exist" do
      create(:percentage_offer_code, code: "SUMMER", amount_percentage: 40)

      expect(described_class.calculate_stats).to eq(active_deals_count: 0, revenue_cents: 0, average_discount_percentage: 0)
    end

    it "counts only alive Black Friday offer codes that are currently valid" do
      create(:percentage_offer_code, code:, amount_percentage: 20)
      create(:offer_code, code:, amount_cents: 100)
      create(:percentage_offer_code, code:, amount_percentage: 50).mark_deleted!
      create(:percentage_offer_code, code:, amount_percentage: 50, valid_at: 1.day.from_now)
      create(:percentage_offer_code, code:, amount_percentage: 50, valid_at: 3.days.ago, expires_at: 1.day.ago)
      create(:percentage_offer_code, code: "SUMMER", amount_percentage: 50)

      expect(described_class.calculate_stats[:active_deals_count]).to eq(2)
    end

    it "averages the percentage of active percentage-off codes, ignoring fixed-amount codes" do
      create(:percentage_offer_code, code:, amount_percentage: 20)
      create(:percentage_offer_code, code:, amount_percentage: 25)
      create(:offer_code, code:, amount_cents: 100)

      expect(described_class.calculate_stats[:average_discount_percentage]).to eq(23)
    end

    it "sums revenue from successful purchases made with Black Friday codes, including expired ones" do
      active_code = create(:percentage_offer_code, code:, amount_percentage: 25)
      expired_code = create(:percentage_offer_code, code:, amount_percentage: 25, valid_at: 3.days.ago, expires_at: 1.day.ago)
      deleted_code = create(:percentage_offer_code, code:, amount_percentage: 25)
      other_code = create(:percentage_offer_code, code: "SUMMER", amount_percentage: 25)

      create_list(:purchase, 2, link: active_code.products.first, offer_code: active_code, price_cents: 750)
      create(:purchase, link: expired_code.products.first, offer_code: expired_code, price_cents: 300)
      create(:failed_purchase, link: active_code.products.first, offer_code: active_code, price_cents: 10_000)
      create(:purchase, link: deleted_code.products.first, offer_code: deleted_code, price_cents: 10_000)
      create(:purchase, link: other_code.products.first, offer_code: other_code, price_cents: 10_000)
      deleted_code.mark_deleted!

      expect(described_class.calculate_stats[:revenue_cents]).to eq(1_800)
    end
  end

  describe ".fetch_stats" do
    before do
      Rails.cache.clear
    end

    after do
      Rails.cache.clear
    end

    it "caches the stats and doesn't recalculate on subsequent calls" do
      expect(described_class).to receive(:calculate_stats).once.and_call_original

      first_result = described_class.fetch_stats
      second_result = described_class.fetch_stats

      expect(first_result).to eq(second_result)
      expect(first_result[:active_deals_count]).to eq(0)
      expect(first_result[:revenue_cents]).to eq(0)
      expect(first_result[:average_discount_percentage]).to eq(0)
    end

    it "uses the correct cache key and expiration" do
      expect(Rails.cache).to receive(:fetch).with(
        "black_friday_stats",
        expires_in: 10.minutes
      ).and_call_original

      described_class.fetch_stats
    end

    it "stores stats in Rails cache" do
      described_class.fetch_stats

      cached_value = Rails.cache.read("black_friday_stats")
      expect(cached_value).to be_present
      expect(cached_value[:active_deals_count]).to eq(0)
      expect(cached_value[:revenue_cents]).to eq(0)
      expect(cached_value[:average_discount_percentage]).to eq(0)
    end

    it "recalculates stats after cache expires" do
      travel_to Time.current do
        first_result = described_class.fetch_stats
        expect(first_result[:active_deals_count]).to eq(0)

        travel 11.minutes

        expect(described_class).to receive(:calculate_stats).and_call_original
        new_result = described_class.fetch_stats
        expect(new_result[:active_deals_count]).to eq(0)
      end
    end

    it "handles cache deletion and recalculates" do
      first_result = described_class.fetch_stats
      expect(first_result[:active_deals_count]).to eq(0)

      Rails.cache.delete("black_friday_stats")

      expect(described_class).to receive(:calculate_stats).and_call_original
      new_result = described_class.fetch_stats
      expect(new_result[:active_deals_count]).to eq(0)
    end
  end
end
