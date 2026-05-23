# frozen_string_literal: true

require "test_helper"

class ApiDomainConstraintTest < ActiveSupport::TestCase
  self.described_class = ApiDomainConstraint



  context_ ApiDomainConstraint do
  context_ ".matches?" do
      before do
        @api_domain_request = double("request")
        allow(@api_domain_request).to receive(:host).and_return("api.gumroad.com")

        @non_api_domain_request = double("request")
        allow(@non_api_domain_request).to receive(:host).and_return("gumroad.com")
      end

  context_ "when in development environment" do
        before do
          allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
        end

  test "returns true" do
          expect(described_class.matches?(@api_domain_request)).to eq(true)
          expect(described_class.matches?(@non_api_domain_request)).to eq(true)
        end
      end

  context_ "when in non-development environments" do
        before do
          stub_const("VALID_API_REQUEST_HOSTS", ["api.gumroad.com"])
        end

  context_ "when requests come from valid API domain" do
  test "returns true" do
            expect(described_class.matches?(@api_domain_request)).to eq(true)
          end
        end

  context_ "when requests come from non-API domain" do
  test "returns false" do
            expect(described_class.matches?(@non_api_domain_request)).to eq(false)
          end
        end
      end
    end
  end
end
