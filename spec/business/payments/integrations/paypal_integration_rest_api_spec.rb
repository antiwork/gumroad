# frozen_string_literal: true

describe PaypalIntegrationRestApi, :vcr do
  before do
    @creator = create(:user, email: "sb-oy4cl2265599@business.example.com")
  end

  describe "create_partner_referral" do
    context "valid inputs" do
      before do
        authorization_header = PaypalPartnerRestCredentials.new.auth_token
        api_object = PaypalIntegrationRestApi.new(@creator, authorization_header:)

        @response = api_object.create_partner_referral("http://example.com")
      end

      it "succeeds and returns links in the response" do
        expect(@response.success?).to eq(true)
        expect(@response.parsed_response["links"].count).to eq(2)
      end
    end

    context "invalid inputs" do
      before do
        api_object = PaypalIntegrationRestApi.new(@creator, authorization_header: "invalid header")
        @response = api_object.create_partner_referral("http://example.com")
      end

      it "fails and returns unauthorized as error" do
        expect(@response.success?).to eq(false)
        expect(@response.code).to eq(401)
      end
    end
  end
end
