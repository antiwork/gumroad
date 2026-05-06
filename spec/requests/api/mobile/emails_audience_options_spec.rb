require "spec_helper"

RSpec.describe "API::Mobile::Emails audience_options", type: :request do
  before { host! VALID_API_REQUEST_HOSTS.first }

  let(:seller) { create(:user, :eligible_sender) }
  let(:token) { create("doorkeeper/access_token", resource_owner_id: seller.id, scopes: "mobile_api") }
  let(:mobile_token) { Api::Mobile::BaseController::MOBILE_TOKEN }
  let(:auth_headers) { { "Authorization" => "Bearer #{token.token}" } }

  before do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    allow_any_instance_of(User).to receive(:has_completed_payouts?).and_return(true)
  end

  describe "GET /mobile/emails/audience_options" do
    it "returns 200 with options + eligibility for an eligible seller" do
      get "/mobile/emails/audience_options", params: { mobile_token: }, headers: auth_headers
      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json["options"]).to be_an(Array)
      expect(json["options"].first).to include("type", "label", "count")
      expect(json["eligibility"]["can_send_emails"]).to be true
      expect(json["eligibility"]["reason"]).to be_nil
    end

    it "returns has_profile_sections: false when seller has no sections" do
      get "/mobile/emails/audience_options", params: { mobile_token: }, headers: auth_headers
      expect(response.parsed_body["has_profile_sections"]).to be false
    end

    it "returns has_profile_sections: true when seller has at least one section" do
      create(:seller_profile_posts_section, seller:)
      get "/mobile/emails/audience_options", params: { mobile_token: }, headers: auth_headers
      expect(response.parsed_body["has_profile_sections"]).to be true
    end

    it "returns can_send_emails: false with $0 sales" do
      poor_seller = create(:user, user_risk_state: "compliant")
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(0)
      poor_token = create("doorkeeper/access_token", resource_owner_id: poor_seller.id, scopes: "mobile_api")
      get "/mobile/emails/audience_options", params: { mobile_token: }, headers: { "Authorization" => "Bearer #{poor_token.token}" }
      json = response.parsed_body
      expect(json["eligibility"]["can_send_emails"]).to be false
      expect(json["eligibility"]["reason"]).to include("$100")
    end

    it "always includes the audience option" do
      get "/mobile/emails/audience_options", params: { mobile_token: }, headers: auth_headers
      types = response.parsed_body["options"].map { |o| o["type"] }
      expect(types).to include("audience")
    end

    it "returns 401 without OAuth bearer" do
      get "/mobile/emails/audience_options", params: { mobile_token: }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 with wrong mobile_token" do
      get "/mobile/emails/audience_options", params: { mobile_token: "wrong" }, headers: auth_headers
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 when token lacks mobile_api scope" do
      scoped_token = create("doorkeeper/access_token", resource_owner_id: seller.id, scopes: "creator_api")
      get "/mobile/emails/audience_options", params: { mobile_token: }, headers: { "Authorization" => "Bearer #{scoped_token.token}" }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
