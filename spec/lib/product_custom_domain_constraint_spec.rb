# frozen_string_literal: true

require "spec_helper"

describe ProductCustomDomainConstraint do
  describe ".matches?" do
    context "when request host is a user custom domain" do
      before do
        @custom_domain_request = double("request")
        allow(@custom_domain_request).to receive(:host).and_return("example.com")
        create(:custom_domain, domain: "example.com")
      end

      it "returns false" do
        expect(described_class.matches?(@custom_domain_request)).to eq(false)
      end
    end

    context "when request host is a product custom domain" do
      before do
        @custom_domain_request = double("request")
        allow(@custom_domain_request).to receive(:host).and_return("example.com")
        create(:custom_domain, :with_product, domain: "example.com")
      end

      it "returns true" do
        expect(described_class.matches?(@custom_domain_request)).to eq(true)
      end
    end
  end
end
