# frozen_string_literal: true

require "spec_helper"

describe DiscoverDomainConstraint do
  describe ".matches?" do
    before do
      @discover_domain_request = double("request")
      allow(@discover_domain_request).to receive(:host).and_return("discover.gumroad.com")

      @non_discover_domain_request = double("request")
      allow(@non_discover_domain_request).to receive(:host).and_return("gumroad.com")

      stub_const("VALID_DISCOVER_REQUEST_HOST", "discover.gumroad.com")
    end

    context "when requests come from valid discover domain" do
      it "returns true" do
        expect(described_class.matches?(@discover_domain_request)).to eq(true)
      end
    end

    context "when requests come from non-discover domain" do
      it "returns false" do
        expect(described_class.matches?(@non_discover_domain_request)).to eq(false)
      end
    end
  end
end
