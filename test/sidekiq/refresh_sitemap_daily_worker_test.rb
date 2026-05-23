# frozen_string_literal: true

require "test_helper"

class RefreshSitemapDailyWorkerTest < ActiveSupport::TestCase
  self.described_class = RefreshSitemapDailyWorker



  context_ RefreshSitemapDailyWorker do
  context_ "#perform" do
      before do
        @product = create(:product, created_at: Time.current)
      end

  test "generates the sitemap" do
        date = @product.created_at
        sitemap_file_path = "#{Rails.public_path}/sitemap/products/monthly/#{date.year}/#{date.month}/sitemap.xml.gz"
        described_class.new.perform

        expect(File.exist?(sitemap_file_path)).to be true
      end

  test "invokes SitemapService" do
        expect_any_instance_of(SitemapService).to receive(:generate)

        described_class.new.perform
      end
    end
  end
end
