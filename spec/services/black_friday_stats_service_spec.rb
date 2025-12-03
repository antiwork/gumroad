# frozen_string_literal: true

require "spec_helper"

describe BlackFridayStatsService do
  describe ".calculate_stats" do
    it "returns placeholder values with zero counts" do
      stats = described_class.calculate_stats

      expect(stats[:active_deals_count]).to eq(0)
      expect(stats[:revenue_cents]).to eq(0)
      expect(stats[:average_discount_percentage]).to eq(0)
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
