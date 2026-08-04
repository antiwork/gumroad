# frozen_string_literal: true

require "spec_helper"

describe RefreshWishlistSitemapDailyWorker do
  describe "#perform" do
    it "generates the wishlist sitemap" do
      service = instance_double(SitemapService)
      allow(SitemapService).to receive(:new).and_return(service)
      expect(service).to receive(:generate_wishlists)

      described_class.new.perform
    end
  end
end
