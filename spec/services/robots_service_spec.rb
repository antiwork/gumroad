# frozen_string_literal: true

require "spec_helper"

describe RobotsService do
  before do
    @redis_namespace = Redis::Namespace.new(:robots_redis_namespace, redis: $redis)
    @sitemap_config = "Sitemap: https://test-public-files.gumroad.com/products/sitemap.xml"
    @user_agent_rules = ["User-agent: *", "Disallow: /purchases/"]
  end

  describe "#sitemap_configs" do
    before do
      s3_double = double(:s3_double)
      response_double = double(:list_objects_response)
      allow(Aws::S3::Client).to receive(:new).and_return(s3_double)
      allow(s3_double).to receive(:list_objects).times.and_return([response_double])
      allow(response_double).to receive(:contents).and_return([OpenStruct.new(key: "products/sitemap.xml")])
    end

    it "generates sitemap configs" do
      expect(described_class.new.sitemap_configs).to eq [@sitemap_config]
      expect(@redis_namespace.get("sitemap_configs")).to eq [@sitemap_config].to_json
    end

    it "doesn't generate sitemaps configs when cache exists" do
      expect_any_instance_of(RobotsService).to receive(:generate_sitemap_configs).once

      2.times do
        RobotsService.new.sitemap_configs
      end
    end
  end

  describe "#user_agent_rules" do
    it "returns the user agent rules" do
      expect(described_class.new.user_agent_rules).to eq @user_agent_rules
    end
  end

  describe "#expire_sitemap_configs_cache" do
    before do
      @redis_namespace.set("sitemap_configs", @sitemap_config)
    end

    it "expires sitemap_configs cache" do
      described_class.new.expire_sitemap_configs_cache

      expect(@redis_namespace.get("sitemap_configs")).to eq nil
    end
  end
end
