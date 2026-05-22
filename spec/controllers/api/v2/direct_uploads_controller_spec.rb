# frozen_string_literal: true

require "spec_helper"
require "digest/md5"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::DirectUploadsController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
  end

  describe "POST 'create'" do
    before do
      @action = :create
      @params = {
        blob: {
          filename: "cover.png",
          byte_size: 1024,
          checksum: Digest::MD5.base64digest("cover image"),
          content_type: "image/png"
        }
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "creates a blob for direct upload and returns the signed blob token" do
        expect do
          post @action, params: @params
        end.to change { ActiveStorage::Blob.count }.by(1)

        expect(response).to be_successful
        body = response.parsed_body
        blob = ActiveStorage::Blob.last
        expect(body["signed_id"]).to eq(blob.signed_id)
        expect(body["filename"]).to eq("cover.png")
        expect(body["byte_size"]).to eq(1024)
        expect(body["checksum"]).to eq(Digest::MD5.base64digest("cover image"))
        expect(body["content_type"]).to eq("image/png")
        expect(body["direct_upload"]["url"]).to be_present
        expect(body["direct_upload"]["headers"]).to be_present
      end

      it "returns a structured error for invalid blob parameters" do
        expect do
          post @action, params: @params.deep_merge(blob: { checksum: nil })
        end.not_to change { ActiveStorage::Blob.count }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq("Checksum can't be blank")
      end

      it "rejects unsupported content types before creating a blob" do
        expect do
          post @action, params: @params.deep_merge(blob: { content_type: "application/pdf" })
        end.not_to change { ActiveStorage::Blob.count }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq("content_type must be JPEG, PNG, GIF, or video.")
      end

      it "rejects WebP images before creating a blob" do
        expect do
          post @action, params: @params.deep_merge(blob: { content_type: "image/webp" })
        end.not_to change { ActiveStorage::Blob.count }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq("content_type must be JPEG, PNG, GIF, or video.")
      end
    end

    it "grants access with the account scope" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
      post @action, params: @params.merge(access_token: token.token)
      expect(response).to be_successful
      expect(response.parsed_body["signed_id"]).to eq(ActiveStorage::Blob.last.signed_id)
    end
  end
end
