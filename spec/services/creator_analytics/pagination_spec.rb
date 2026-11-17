# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Pagination do
  describe ".within_budget" do
    it "sets a deadline for the block and clears it after" do
      described_class.within_budget do
        expect(Current.analytics_pagination_deadline).to be_present
        expect(described_class.exhausted?(pages: 0)).to eq(false)
      end

      expect(Current.analytics_pagination_deadline).to be_nil
    end

    it "clears the deadline when the block raises" do
      expect { described_class.within_budget { raise "boom" } }.to raise_error("boom")

      expect(Current.analytics_pagination_deadline).to be_nil
    end
  end

  describe ".exhausted?" do
    it "is false with no request budget open, so work outside a request is not cut off" do
      expect(described_class.exhausted?(pages: 0)).to eq(false)
      expect(described_class.exhausted?(pages: described_class::MAX_PAGES)).to eq(false)
    end

    it "is true once the request deadline has passed" do
      described_class.within_budget do
        Current.analytics_pagination_deadline = described_class.monotonic_now - 1

        expect(described_class.exhausted?(pages: 0)).to eq(true)
      end
    end

    it "is true at the page cap even while the deadline holds" do
      described_class.within_budget do
        expect(described_class.exhausted?(pages: described_class::MAX_PAGES)).to eq(true)
        expect(described_class.exhausted?(pages: described_class::MAX_PAGES - 1)).to eq(false)
      end
    end
  end
end
