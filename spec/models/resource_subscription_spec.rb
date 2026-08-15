# frozen_string_literal: true

require "spec_helper"

describe ResourceSubscription do
  before do
    @user = create(:user)
  end

  describe "#assign_content_type_to_json_for_zapier" do
    it "sets content_type to application/json for Zapier subscriptions" do
      resource_subscription = create(:resource_subscription, post_url: "https://hooks.zapier.com/sample", user: @user)
      expect(resource_subscription.content_type).to eq "application/json"
    end

    it "doesn't overwrite the default content_type application/x-www-form-urlencoded for non-Zapier subscriptions" do
      resource_subscription = create(:resource_subscription, post_url: "https://hooks.example.com/sample", user: @user)
      expect(resource_subscription.content_type).to eq "application/x-www-form-urlencoded"
    end
  end

  describe ".valid_post_url?", :skip_resource_subscription_dns_stub do
    def stub_resolution(hostname, *ips)
      allow(ResourceSubscription).to receive(:resolve_addresses).with(hostname).and_return(ips.map { |ip| IPAddr.new(ip) })
    end

    it "allows a hostname that resolves only to public addresses" do
      stub_resolution("hooks.example.com", "93.184.216.34")
      expect(ResourceSubscription.valid_post_url?("https://hooks.example.com/path")).to eq(true)
    end

    it "rejects a non-HTTP scheme" do
      expect(ResourceSubscription.valid_post_url?("ftp://hooks.example.com/path")).to eq(false)
    end

    it "rejects an unparseable URL" do
      expect(ResourceSubscription.valid_post_url?("foo bar")).to eq(false)
    end

    it "rejects the exact literal hostnames the old blocklist covered" do
      stub_resolution("127.0.0.1", "127.0.0.1")
      stub_resolution("localhost", "127.0.0.1")
      stub_resolution("0.0.0.0", "0.0.0.0")
      expect(ResourceSubscription.valid_post_url?("http://127.0.0.1/path")).to eq(false)
      expect(ResourceSubscription.valid_post_url?("http://localhost/path")).to eq(false)
      expect(ResourceSubscription.valid_post_url?("http://0.0.0.0/path")).to eq(false)
    end

    it "rejects a loopback address the literal blocklist missed (127.0.0.2)" do
      stub_resolution("loopback-variant.example.com", "127.0.0.2")
      expect(ResourceSubscription.valid_post_url?("http://loopback-variant.example.com/path")).to eq(false)
    end

    it "rejects RFC1918 private ranges" do
      stub_resolution("internal.example.com", "10.0.0.5")
      expect(ResourceSubscription.valid_post_url?("http://internal.example.com/path")).to eq(false)
    end

    it "rejects the link-local cloud metadata address" do
      stub_resolution("metadata.example.com", "169.254.169.254")
      expect(ResourceSubscription.valid_post_url?("http://metadata.example.com/path")).to eq(false)
    end

    it "rejects IPv6 loopback and unique-local ranges" do
      stub_resolution("v6-loopback.example.com", "::1")
      expect(ResourceSubscription.valid_post_url?("http://v6-loopback.example.com/path")).to eq(false)

      stub_resolution("v6-ula.example.com", "fd00::1")
      expect(ResourceSubscription.valid_post_url?("http://v6-ula.example.com/path")).to eq(false)
    end

    it "rejects a literal IPv6 loopback host" do
      stub_resolution("::1", "::1")
      expect(ResourceSubscription.valid_post_url?("http://[::1]/path")).to eq(false)
    end

    it "rejects a hostname that resolves to a private address even though its string looks public (DNS rebinding)" do
      stub_resolution("looks-public-but-rebinds.com", "10.1.2.3")
      expect(ResourceSubscription.valid_post_url?("http://looks-public-but-rebinds.com/path")).to eq(false)
    end

    it "rejects a hostname with a mix of public and private resolved addresses" do
      stub_resolution("mixed.example.com", "93.184.216.34", "127.0.0.1")
      expect(ResourceSubscription.valid_post_url?("http://mixed.example.com/path")).to eq(false)
    end

    it "rejects a hostname that fails to resolve" do
      stub_resolution("nonexistent.invalid")
      expect(ResourceSubscription.valid_post_url?("http://nonexistent.invalid/path")).to eq(false)
      expect(ResourceSubscription.post_url_delivery_status("http://nonexistent.invalid/path")).to eq(:unresolved)
    end

    it "classifies reserved, invalid, and public URLs separately" do
      stub_resolution("hooks.example.com", "93.184.216.34")
      stub_resolution("internal.example.com", "10.0.0.5")
      expect(ResourceSubscription.post_url_delivery_status("https://hooks.example.com/path")).to eq(:ok)
      expect(ResourceSubscription.post_url_delivery_status("http://internal.example.com/path")).to eq(:reserved)
      expect(ResourceSubscription.post_url_delivery_status("ftp://hooks.example.com/path")).to eq(:invalid)
      expect(ResourceSubscription.post_url_delivery_status("foo bar")).to eq(:invalid)
    end
  end
end
