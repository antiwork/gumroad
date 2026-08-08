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

  describe ".valid_post_url?" do
    it "allows public HTTP and HTTPS URLs" do
      allow(Resolv).to receive(:getaddresses).with("hooks.example.com").and_return(["203.0.114.10"])

      expect(described_class.valid_post_url?("https://hooks.example.com/path", require_resolvable: true)).to be(true)
      expect(described_class.valid_post_url?("http://hooks.example.com/path", require_resolvable: true)).to be(true)
    end

    it "rejects private, loopback, link-local, and malformed numeric hosts" do
      expect(described_class.valid_post_url?("http://127.0.0.2/path")).to be(false)
      expect(described_class.valid_post_url?("http://0177.0.0.1/path")).to be(false)
      expect(described_class.valid_post_url?("http://169.254.169.254/latest/meta-data/")).to be(false)
      expect(described_class.valid_post_url?("http://[::1]/path")).to be(false)
      expect(described_class.valid_post_url?("http://[fc00::1]/path")).to be(false)
    end

    it "allows public IPv4 and IPv6 literal post_urls for delivery-time validation" do
      # Resolv.getaddresses never resolves IP literals (ruby-lang bug #17112), so this
      # must short-circuit on the literal itself rather than fall through to the
      # require_resolvable branch, which would otherwise silently drop delivery.
      expect(described_class.valid_post_url?("http://52.1.2.3/webhook", require_resolvable: true)).to be(true)
      expect(described_class.valid_post_url?("http://[2600::1]/hook", require_resolvable: true)).to be(true)
    end

    it "rejects DNS names that resolve to blocked addresses when resolution is required" do
      allow(Resolv).to receive(:getaddresses).with("metadata.example.com").and_return(["169.254.169.254"])
      allow(Resolv).to receive(:getaddresses).with("mixed.example.com").and_return(["203.0.114.10", "10.0.0.5"])

      expect(described_class.valid_post_url?("https://metadata.example.com/hook", require_resolvable: true)).to be(false)
      expect(described_class.valid_post_url?("https://mixed.example.com/hook", require_resolvable: true)).to be(false)
    end

    it "allows unresolved DNS names at creation but rejects them for delivery-time validation" do
      allow(Resolv).to receive(:getaddresses).with("pending.example.com").and_return([])

      expect(described_class.valid_post_url?("https://pending.example.com/hook")).to be(true)
      expect(described_class.valid_post_url?("https://pending.example.com/hook", require_resolvable: true)).to be(false)
    end

    it "rejects non-HTTP URLs and invalid input" do
      expect(described_class.valid_post_url?("ftp://example.com/hook")).to be(false)
      expect(described_class.valid_post_url?("foo bar")).to be(false)
      expect(described_class.valid_post_url?(nil)).to be(false)
    end
  end
end
