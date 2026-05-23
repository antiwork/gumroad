# frozen_string_literal: true

require "test_helper"

class SitemapServiceTest < ActiveSupport::TestCase
  self.described_class = SitemapService



  context_ SitemapService do
    let(:service) { described_class.new }

  context_ "#generate" do
      before do
        @product = create(:product, created_at: Time.current)
      end

  test "generates the sitemap" do
        date = @product.created_at
        sitemap_file_path = "#{Rails.public_path}/sitemap/products/monthly/#{date.year}/#{date.month}/sitemap.xml.gz"
        service.generate(date)

        expect(File.exist?(sitemap_file_path)).to be true
      end

  test "deletes /robots.txt sitemap configs cache" do
        cache_key = "sitemap_configs"
        redis_namespace = Redis::Namespace.new(:robots_redis_namespace, redis: $redis)
        redis_namespace.set("sitemap_configs", "[\"https://example.com/robots.txt\"]")

        service.generate(@product.created_at)

        expect(redis_namespace.get(cache_key)).to eq nil
      end
    end
  end
end
