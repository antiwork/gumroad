require "spec_helper"

RSpec.describe "API::Mobile::Emails index", type: :request do
  before { host! VALID_API_REQUEST_HOSTS.first }

  let(:seller) { create(:user, :eligible_sender) }
  let(:token) { create("doorkeeper/access_token", resource_owner_id: seller.id, scopes: "mobile_api") }
  let(:mobile_token) { Api::Mobile::BaseController::MOBILE_TOKEN }
  let(:auth_headers) { { "Authorization" => "Bearer #{token.token}" } }

  describe "GET /mobile/emails" do
    it "returns 200 with empty installments for an eligible seller with no posts" do
      get "/mobile/emails", params: { mobile_token: }, headers: auth_headers
      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json["installments"]).to eq([])
      expect(json["pagination"]).to eq({ "count" => 0, "next" => nil })
      expect(json["has_posts"]).to be false
    end

    it "returns published installments for the seller" do
      published = create(:installment, :published, seller:, name: "Latest update")
      create(:installment, seller:, name: "Draft only")
      other_seller = create(:user, :eligible_sender)
      create(:installment, :published, seller: other_seller, name: "Other seller's post")

      get "/mobile/emails", params: { mobile_token: }, headers: auth_headers
      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      names = json["installments"].map { _1["name"] }
      expect(names).to contain_exactly("Latest update")
      expect(json["installments"].first["external_id"]).to eq(published.external_id)
      expect(json["has_posts"]).to be true
    end

    it "exposes the stat fields the mobile detail sheet needs" do
      create(:installment, :published, seller:)
      get "/mobile/emails", params: { mobile_token: }, headers: auth_headers
      row = response.parsed_body["installments"].first
      %w[
        external_id name published_at sent_count open_count click_count
        view_count open_rate click_rate send_emails shown_on_profile
        installment_type full_url has_been_blasted
      ].each do |field|
        expect(row).to have_key(field), "expected installment row to expose #{field}"
      end
    end

    it "paginates at 25 results per page" do
      26.times { create(:installment, :published, seller:) }
      get "/mobile/emails", params: { mobile_token: }, headers: auth_headers
      json = response.parsed_body
      expect(json["installments"].length).to eq(25)
      expect(json["pagination"]["count"]).to eq(26)
      expect(json["pagination"]["next"]).to eq(2)
    end

    it "returns the second page when page=2" do
      26.times { create(:installment, :published, seller:) }
      get "/mobile/emails", params: { mobile_token:, page: 2 }, headers: auth_headers
      json = response.parsed_body
      expect(json["installments"].length).to eq(1)
      expect(json["pagination"]["next"]).to be_nil
    end

    it "returns 401 without OAuth bearer" do
      get "/mobile/emails", params: { mobile_token: }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 with wrong mobile_token" do
      get "/mobile/emails", params: { mobile_token: "wrong" }, headers: auth_headers
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 when token lacks mobile_api scope" do
      scoped_token = create("doorkeeper/access_token", resource_owner_id: seller.id, scopes: "creator_api")
      get "/mobile/emails", params: { mobile_token: }, headers: { "Authorization" => "Bearer #{scoped_token.token}" }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
