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

      it "returns structured errors when required blob parameters are omitted" do
        [:filename, :byte_size, :checksum].each do |field|
          expect do
            post @action, params: @params.deep_dup.tap { |params| params[:blob].delete(field) }
          end.not_to change { ActiveStorage::Blob.count }

          expect(response).to have_http_status(:bad_request)
          expect(response.parsed_body["error"]).to eq("#{field} is required")
        end
      end

      it "ignores client-supplied metadata" do
        post @action, params: @params.deep_merge(blob: { metadata: { analyzed: true, width: 500, height: 500, duration: 120 } })

        expect(response).to be_successful
        blob = ActiveStorage::Blob.last
        expect(blob.metadata).not_to include("analyzed", "width", "height", "duration")
      end

      it "rejects missing content type before creating a blob" do
        expect do
          post @action, params: @params.deep_dup.tap { |params| params[:blob].delete(:content_type) }
        end.not_to change { ActiveStorage::Blob.count }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq("content_type must be JPEG, PNG, GIF, or video.")
      end

      it "rejects byte sizes above the upload maximum before creating a blob" do
        expect do
          post @action, params: @params.deep_merge(blob: { byte_size: described_class::MAX_FILE_SIZE + 1 })
        end.not_to change { ActiveStorage::Blob.count }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq("byte_size exceeds the #{described_class::MAX_FILE_SIZE_GB} GB maximum")
      end

      it "rejects non-positive byte sizes before creating a blob" do
        [0, -1].each do |byte_size|
          expect do
            post @action, params: @params.deep_merge(blob: { byte_size: })
          end.not_to change { ActiveStorage::Blob.count }

          expect(response).to have_http_status(:bad_request)
          expect(response.parsed_body["error"]).to eq("byte_size is required")
        end
      end

      it "rejects unsupported content types before creating a blob" do
        expect do
          post @action, params: @params.deep_merge(blob: { content_type: "application/pdf" })
        end.not_to change { ActiveStorage::Blob.count }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq("content_type must be JPEG, PNG, GIF, or video.")
      end

      it "rejects content types with extra trailing characters before creating a blob" do
        expect do
          post @action, params: @params.deep_merge(blob: { content_type: "image/gifscript" })
        end.not_to change { ActiveStorage::Blob.count }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq("content_type must be JPEG, PNG, GIF, or video.")
      end

      it "rejects empty video subtypes before creating a blob" do
        expect do
          post @action, params: @params.deep_merge(blob: { content_type: "video/" })
        end.not_to change { ActiveStorage::Blob.count }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq("content_type must be JPEG, PNG, GIF, or video.")
      end

      it "rejects non-string content types before creating a blob" do
        expect do
          post @action, params: @params.deep_merge(blob: { content_type: 123 })
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
