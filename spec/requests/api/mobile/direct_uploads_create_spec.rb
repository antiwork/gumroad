# spec/requests/mobile/direct_uploads_create_spec.rb
require "spec_helper"

RSpec.describe "API::Mobile::DirectUploads", type: :request do
  before { host! VALID_API_REQUEST_HOSTS.first }

  let(:seller) { create(:user, user_risk_state: "compliant") }
  let(:token) { create("doorkeeper/access_token", resource_owner_id: seller.id, scopes: "creator_api mobile_api") }
  let(:mobile_token) { Api::Mobile::BaseController::MOBILE_TOKEN }
  let(:auth_headers) { { "Authorization" => "Bearer #{token.token}" } }

  describe "POST /mobile/direct_uploads" do
    let(:blob_params) do
      { blob: { filename: "photo.jpg", byte_size: 1024, checksum: Digest::MD5.base64digest("fake"), content_type: "image/jpeg" } }
    end

    it "returns 200 with signed_id and direct_upload payload" do
      post "/mobile/direct_uploads", params: blob_params.merge(mobile_token:), headers: auth_headers
      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json["signed_id"]).to be_present
      expect(json["key"]).to be_present
      expect(json["direct_upload"]["url"]).to start_with("http")
      expect(json["direct_upload"]["headers"]).to be_a(Hash)
      expect(ActiveStorage::Blob.find_signed!(json["signed_id"])).to have_attributes(key: json["key"], filename: ActiveStorage::Filename.new("photo.jpg"))
    end

    it "returns 401 without OAuth bearer" do
      post "/mobile/direct_uploads", params: blob_params.merge(mobile_token:)
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 with wrong mobile_token" do
      post "/mobile/direct_uploads", params: blob_params.merge(mobile_token: "wrong"), headers: auth_headers
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 when token lacks mobile_api scope" do
      scoped_token = create("doorkeeper/access_token", resource_owner_id: seller.id, scopes: "creator_api")
      post "/mobile/direct_uploads", params: blob_params.merge(mobile_token:), headers: { "Authorization" => "Bearer #{scoped_token.token}" }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
