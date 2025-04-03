# frozen_string_literal: true

require "spec_helper"

describe RefreshSitemapDailyWorker do
  describe "#perform" do
    before do
      @product = create(:product, created_at: Time.current)
    end

    it "generates the sitemap" do
      date = @product.created_at
      sitemap_file_path = "#{Rails.public_path}/sitemap/products/monthly/#{date.year}/#{date.month}/sitemap.xml.gz"
      described_class.new.perform

      expect(File.exist?(sitemap_file_path)).to be true
    end

    it "invokes SitemapService" do
      expect_any_instance_of(SitemapService).to receive(:generate)

      described_class.new.perform
    end
  end
end
