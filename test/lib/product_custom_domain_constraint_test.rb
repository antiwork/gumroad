# frozen_string_literal: true

require "test_helper"

class ProductCustomDomainConstraintTest < ActiveSupport::TestCase
  self.described_class = ProductCustomDomainConstraint



  context_ ProductCustomDomainConstraint do
  context_ ".matches?" do
  context_ "when request host is a user custom domain" do
        before do
          @custom_domain_request = double("request")
          allow(@custom_domain_request).to receive(:host).and_return("example.com")
          create(:custom_domain, domain: "example.com")
        end

  test "returns false" do
          expect(described_class.matches?(@custom_domain_request)).to eq(false)
        end
      end

  context_ "when request host is a product custom domain" do
        before do
          @custom_domain_request = double("request")
          allow(@custom_domain_request).to receive(:host).and_return("example.com")
          create(:custom_domain, :with_product, domain: "example.com")
        end

  test "returns true" do
          expect(described_class.matches?(@custom_domain_request)).to eq(true)
        end
      end
    end
  end
end
