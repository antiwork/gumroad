# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe S3UtilityController do
  include CdnUrlHelper

  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  it_behaves_like "authorize called for controller", S3UtilityPolicy do
    let(:record) { :s3_utility }
  end

  describe "GET generate_multipart_signature" do
    it "doesn't allow sellers to sign request for buckets they do not own" do
      sign_string = "POST\n\nvideo/quicktime; charset=UTF-8\n\nx-amz-acl:private\nx-amz-date:Mon, 02 Mar 2015 17:21:19 \
      GMT\n/gumroad-specs/attachments/#{seller.external_id + 'invalid'}/bf03be06616f4dfd88da7c37005a9b2f/original/capturedvideo%20(1)-5-2.mov?uploads"
      get :generate_multipart_signature, params: { to_sign: sign_string }

      expect(response.parsed_body["success"]).to be(false)
      expect(response).to be_forbidden
    end

    it "doesn't allow if an attacker splits the request with newlines" do
      sign_string = "GET /?response-content-type=\n/gumroad-specs/attachments/#{seller.external_id}/test"
      get :generate_multipart_signature, params: { to_sign: sign_string }

      expect(response.parsed_body["success"]).to be(false)
      expect(response).to be_forbidden
    end

    it "allows sellers to sign request for buckets they own" do
      sign_string = "POST\n\nvideo/quicktime; charset=UTF-8\n\nx-amz-acl:private\nx-amz-date:Mon, 02 Mar 2015 17:21:19 \
      GMT\n/gumroad-specs/attachments/#{seller.external_id}/bf03be06616f4dfd88da7c37005a9b2f/original/capturedvideo%20(1)-5-2.mov?uploads"
      get :generate_multipart_signature, params: { to_sign: sign_string }

      expect(response).to be_successful
    end
  end

  describe "GET cdn_url_for_blob" do
    it "returns blob cdn url with valid key" do
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")

      get :cdn_url_for_blob, params: { key: blob.key }

      expect(response).to redirect_to (cdn_url_for(blob.url))
    end

    it "404s with an invalid key" do
      expect do
        get :cdn_url_for_blob, params: { key: "xxx" }
      end.to raise_error(ActionController::RoutingError)
    end

    it "returns the blob cdn url in JSON format" do
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")

      get :cdn_url_for_blob, params: { key: blob.key }, format: :json

      expect(response.parsed_body["url"]).to eq(cdn_url_for(blob.url))
    end
  end
end
