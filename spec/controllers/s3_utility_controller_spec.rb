# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"
require "shared_examples/authorize_called"

describe S3UtilityController do
  include CdnUrlHelper

  let(:seller) { create(:user) }
  let(:another_user) { create(:user) }

  before { sign_in seller }

  it_behaves_like "authorize called for controller", S3UtilityPolicy do
    let(:record) { :s3_utility }
  end

  describe "GET generate_multipart_signature" do
    it_behaves_like "authentication required for action", :get, :generate_multipart_signature

    it "doesn't allow users to sign request for buckets they do not own" do
      get :generate_multipart_signature, params: {
        to_sign: payload_to_sign(another_user.external_id)
      }

      expect(response).to have_http_status(:forbidden)
    end

    it "doesn't allow if an attacker splits the request with newlines" do
      sign_string = "GET /?response-content-type=\n/gumroad-specs/attachments/#{seller.external_id}/test"
      get :generate_multipart_signature, params: { to_sign: sign_string }

      expect(response).to have_http_status(:forbidden)
    end

    it "allows users to sign request for their own buckets" do
      get :generate_multipart_signature, params: {
        to_sign: payload_to_sign(seller.external_id)
      }

      expect(response).to have_http_status(:ok)
    end

    context "when the user has admin access to the seller" do
      include_context "with user signed in as admin for seller"

      it "allows signing" do
        get :generate_multipart_signature, params: {
          to_sign: payload_to_sign(seller.external_id)
        }

        expect(response).to have_http_status(:ok)
      end
    end

    context "when the user has marketing access to the seller" do
      include_context "with user signed in as marketing for seller"

      it "allows signing" do
        get :generate_multipart_signature, params: {
          to_sign: payload_to_sign(seller.external_id)
        }

        expect(response).to have_http_status(:ok)
      end
    end

    context "when the user has accountant access to the seller" do
      include_context "with user signed in as accountant for seller"

      it "does not allow signing" do
        get :generate_multipart_signature, params: {
          to_sign: payload_to_sign(seller.external_id)
        }

        expect(response).to have_http_status(:forbidden)
      end
    end

    context "when the user has support access to the seller" do
      include_context "with user signed in as support for seller"

      it "does not allow signing" do
        get :generate_multipart_signature, params: {
          to_sign: payload_to_sign(seller.external_id)
        }

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "GET current_utc_time_string" do
    it_behaves_like "authentication required for action", :get, :current_utc_time_string

    it "returns the current UTC time in HTTP-Date format" do
      freeze_time

      get :current_utc_time_string

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(Time.current.httpdate)
    end
  end

  describe "GET cdn_url_for_blob" do
    it_behaves_like "authentication required for action", :get, :cdn_url_for_blob

    it "returns blob cdn url with valid key" do
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")

      get :cdn_url_for_blob, params: { key: blob.key }

      expect(response).to redirect_to (cdn_url_for(blob.url))
    end

    it "404s with an invalid key" do
      expect do
        get :cdn_url_for_blob, params: { key: "xxx" }
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "returns the blob cdn url in JSON format" do
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")

      get :cdn_url_for_blob, params: { key: blob.key }, format: :json

      expect(response.parsed_body["url"]).to eq(cdn_url_for(blob.url))
    end
  end

  def payload_to_sign(external_id)
    "POST\n\nvideo/quicktime; charset=UTF-8\n\nx-amz-acl:private\nx-amz-date:Mon, 02 Mar 2015 17:21:19 \
    GMT\n/gumroad-specs/attachments/#{external_id}/bf03be06616f4dfd88da7c37005a9b2f/original/capturedvideo%20(1)-5-2.mov?uploads"
  end
end
