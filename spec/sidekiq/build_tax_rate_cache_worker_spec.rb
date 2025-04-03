# frozen_string_literal: true

require "spec_helper"

describe BuildTaxRateCacheWorker do
  describe ".perform" do
    it "caches the maximum tax rate per state to be used in the product edit flow" do
      create(:zip_tax_rate, combined_rate: 0.09, state: "CA")
      create(:zip_tax_rate, combined_rate: 0.095, state: "CA")
      create(:zip_tax_rate, combined_rate: 0.1, state: "CA")
      create(:zip_tax_rate, combined_rate: 0.08, state: "TX")

      # Show it does not fail for nil states (VAT rates)
      create(:zip_tax_rate, combined_rate: 0.08, state: nil, zip_code: nil, country: "DE")
      create(:zip_tax_rate, combined_rate: 0.08, state: nil, zip_code: nil, country: "GB")

      described_class.new.perform

      expect(ZipTaxRate.where(state: "WA").first).to be_nil

      us_tax_cache_namespace = Redis::Namespace.new(:max_tax_rate_per_state_cache_us, redis: $redis)
      expect(us_tax_cache_namespace.get("US_CA")).to eq("0.1")
      expect(us_tax_cache_namespace.get("US_TX")).to eq("0.08")
      expect(us_tax_cache_namespace.get("US_WA")).to eq(nil)
    end
  end
end
