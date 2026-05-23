# frozen_string_literal: true

require "test_helper"

class PaypalIntegrationRestApiTest < ActiveSupport::TestCase
  self.described_class = PaypalIntegrationRestApi
  self.rspec_metadata = { vcr: true }


  context_ PaypalIntegrationRestApi, :vcr do
    before do
      @creator = create(:user, email: "sb-oy4cl2265599@business.example.com")
    end

  context_ "create_partner_referral" do
  context_ "valid inputs" do
        before do
          authorization_header = PaypalPartnerRestCredentials.new.auth_token
          api_object = PaypalIntegrationRestApi.new(@creator, authorization_header:)

          @response = api_object.create_partner_referral("http://example.com")
        end

  test "succeeds and returns links in the response" do
          expect(@response.success?).to eq(true)
          expect(@response.parsed_response["links"].count).to eq(2)
        end
      end

  context_ "invalid inputs" do
        before do
          api_object = PaypalIntegrationRestApi.new(@creator, authorization_header: "invalid header")
          @response = api_object.create_partner_referral("http://example.com")
        end

  test "fails and returns unauthorized as error" do
          expect(@response.success?).to eq(false)
          expect(@response.code).to eq(401)
        end
      end
    end
  end
end
