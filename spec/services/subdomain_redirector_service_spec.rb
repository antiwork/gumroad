# frozen_string_literal: true

require "spec_helper"

describe SubdomainRedirectorService do
  let(:service) { described_class.new }

  describe "#update" do
    it "sets the config in redis" do
      config = "live.gumroad.com=example.com\ntwitter.gumroad.com=twitter.com/gumroad"
      service.update(config)

      redis_namespace = Redis::Namespace.new(:subdomain_redirect_namespace, redis: $redis)
      expect(redis_namespace.get("subdomain_redirects_config")).to eq config
    end
  end

  describe "#redirects" do
    let(:redis_key) { "subdomain_redirect_namespace:subdomain_redirects_config" }

    it "reads Redis once while the config is empty, then serves later lookups from the cache" do
      expect($redis).to receive(:get).with(redis_key).once.and_call_original

      expect(described_class.new.redirects).to eq({})
      expect(described_class.new.redirects).to eq({})
    end

    it "reads Redis again once the config is updated" do
      expect(described_class.new.redirects).to eq({})

      service.update("live.gumroad.com=example.com")

      expect(described_class.new.redirects).to eq({ "live.gumroad.com" => "example.com" })
    end

    it "degrades to no redirects when the Redis read stalls" do
      allow($redis).to receive(:get).with(redis_key).and_raise(RedisClient::Error.new("Waited 1.0 seconds"))

      expect(service.redirects).to eq({})
      expect(Rails.cache.exist?("subdomain_redirects_cache_key")).to be(false)
    end
  end

  describe "#redirect_urL_for" do
    before do
      config = "live.gumroad.com=example.com\ntwitter.gumroad.com/123=twitter.com/gumroad"
      service.update(config)
    end

    context "when path is empty" do
      it "finds the correct redirect_url" do
        request = double("request")
        allow(request).to receive(:host).and_return("live.gumroad.com")
        allow(request).to receive(:fullpath).and_return("/")

        expect(service.redirect_url_for(request)).to eq "example.com"
      end
    end

    context "when path is not empty" do
      it "finds the correct redirect_url" do
        request = double("request")
        allow(request).to receive(:host).and_return("twitter.gumroad.com")
        allow(request).to receive(:fullpath).and_return("/123")

        expect(service.redirect_url_for(request)).to eq "twitter.com/gumroad"
      end
    end
  end

  describe "#hosts_to_redirect" do
    before do
      config = "live.gumroad.com=example.com\ntwitter.gumroad.com=twitter.com/gumroad"
      service.update(config)
    end

    it "returns a hash of hosts and redirect locations" do
      config = "live.gumroad.com=example.com\ntwitter.gumroad.com=twitter.com/gumroad"
      service.update(config)

      expect(service.redirects).to eq({ "live.gumroad.com" => "example.com", "twitter.gumroad.com" => "twitter.com/gumroad" })
    end

    it "strips host and location" do
      config = "live.gumroad.com   = example.com"
      service.update(config)

      expect(service.redirects).to eq({ "live.gumroad.com" => "example.com" })
    end

    it "splits the config line correctly" do
      config = "live.gumroad.com=https://gumroad.com/test?hello=world"
      service.update(config)

      expect(service.redirects).to eq({ "live.gumroad.com" => "https://gumroad.com/test?hello=world" })
    end

    it "ignores invalid config lines" do
      config = "abcd\nlive.gumroad.com=example.com"
      service.update(config)

      expect(service.redirects).to eq({ "live.gumroad.com" => "example.com" })
    end

    it "ignores protected domains" do
      stub_const("SubdomainRedirectorService::PROTECTED_HOSTS", ["example.com"])

      config = "example.com=gumroad.com\ntwitter.gumroad.com=twitter.com/gumroad"
      service.update(config)

      expect(service.redirects).to eq({ "twitter.gumroad.com" => "twitter.com/gumroad" })
    end
  end

  describe "#redirect_config_as_text" do
    before do
      stub_const("SubdomainRedirectorService::PROTECTED_HOSTS", ["example.com"])
      config = "example.com=gumroad.com\ntwitter.gumroad.com=twitter.com/gumroad"
      service.update(config)
    end

    it "returns redirect config as text after skipping protected domains" do
      expect(service.redirect_config_as_text).to eq "twitter.gumroad.com=twitter.com/gumroad"
    end
  end
end
