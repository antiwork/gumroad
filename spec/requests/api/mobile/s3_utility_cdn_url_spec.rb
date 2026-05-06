# spec/requests/api/mobile/s3_utility_cdn_url_spec.rb
require "spec_helper"

RSpec.describe "API::Mobile::S3Utility", type: :request do
  before { host! VALID_API_REQUEST_HOSTS.first }

  let(:seller) { create(:user, user_risk_state: "compliant") }
  let(:token) { create("doorkeeper/access_token", resource_owner_id: seller.id, scopes: "creator_api mobile_api") }
  let(:mobile_token) { Api::Mobile::BaseController::MOBILE_TOKEN }
  let(:auth_headers) { { "Authorization" => "Bearer #{token.token}" } }
  let(:blob) { ActiveStorage::Blob.create_before_direct_upload!(filename: "photo.jpg", byte_size: 1024, checksum: Digest::MD5.base64digest("x"), content_type: "image/jpeg") }

  describe "GET /mobile/s3_utility/cdn_url_for_blob" do
    it "returns 200 with stable url for existing blob" do
      get "/mobile/s3_utility/cdn_url_for_blob", params: { key: blob.key, mobile_token: }, headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["url"]).to be_present
    end

    it "returns 404 for non-existent key" do
      get "/mobile/s3_utility/cdn_url_for_blob", params: { key: "missing", mobile_token: }, headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 401 without OAuth bearer" do
      get "/mobile/s3_utility/cdn_url_for_blob", params: { key: blob.key, mobile_token: }
      expect(response).to have_http_status(:unauthorized)
    end

    it "PR-8: returns CDN-rewritten URL when CDN_URL_MAP has a matching origin" do
      stub_const("CDN_URL_MAP", { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}" => "https://test-cdn.example.com" })
      blob = ActiveStorage::Blob.create_before_direct_upload!(filename: "x.jpg", byte_size: 1, checksum: Digest::MD5.base64digest("y"), content_type: "image/jpeg")
      get "/mobile/s3_utility/cdn_url_for_blob", params: { key: blob.key, mobile_token: }, headers: auth_headers
      expect(response.parsed_body["url"]).to start_with("https://test-cdn.example.com")
    end
  end
end
