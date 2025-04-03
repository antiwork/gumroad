# frozen_string_literal: true

require "spec_helper"

describe UserCustomDomainConstraint do
  describe ".matches?" do
    context "when request doesn't come from subdomain or custom domain" do
      before do
        @gumroad_domain_request = double("request")
        allow(@gumroad_domain_request).to receive(:host).and_return("gumroad.com")
        allow(@gumroad_domain_request).to receive(:fullpath).and_return("/")
      end

      it "returns false" do
        expect(described_class.matches?(@gumroad_domain_request)).to eq(false)
      end
    end

    context "when request comes from subdomain" do
      before do
        @subdomain_request = double("request")
        allow(@subdomain_request).to receive(:host).and_return("sample.gumroad.com")
        allow(@subdomain_request).to receive(:subdomains).and_return(["sample"])
        stub_const("ROOT_DOMAIN", "gumroad.com")
        create(:user, username: "sample")
      end

      it "returns true" do
        expect(described_class.matches?(@subdomain_request)).to eq(true)
      end
    end

    context "when request comes from custom domain" do
      before do
        @custom_domain_request = double("request")
        allow(@custom_domain_request).to receive(:host).and_return("example.com")
        create(:custom_domain, domain: "example.com", user: create(:user, username: "sample"))
      end

      it "returns true" do
        expect(described_class.matches?(@custom_domain_request)).to eq(true)
      end
    end

    context "when request comes from a host that's configured to redirect" do
      before do
        allow_any_instance_of(SubdomainRedirectorService).to receive(:redirects).and_return({ "live.gumroad.com" => "https://example.com" })
        @custom_domain_request = double("request")
        allow(@custom_domain_request).to receive(:host).and_return("live.gumroad.com")
        allow(@custom_domain_request).to receive(:fullpath).and_return("/")
      end

      it "returns true" do
        expect(described_class.matches?(@custom_domain_request)).to eq(true)
      end
    end
  end
end
