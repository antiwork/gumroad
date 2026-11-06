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
    let(:x_amz_date) { "x-amz-date:Mon, 02 Mar 2015 17:21:19 GMT" }
    let(:resource) { "/#{S3_BUCKET}/attachments/#{seller.external_id}/bf03be06616f4dfd88da7c37005a9b2f/original/capturedvideo%20(1)-5-2.mov" }

    def expect_unauthorized(to_sign)
      get :generate_multipart_signature, params: { to_sign: }

      expect(response).to be_forbidden
      expect(response.parsed_body["success"]).to be(false)
    end

    it "signs the requests Evaporate makes to initiate, upload a part of and complete a multipart upload" do
      [
        "POST\n\nvideo/quicktime; charset=UTF-8\n\nx-amz-acl:private\n#{x_amz_date}\n#{resource}?uploads",
        "PUT\n\nvideo/quicktime; charset=UTF-8\n\n#{x_amz_date}\n#{resource}?partNumber=1&uploadId=2~iCw_lDY8VoNw.OB-Pk",
        "POST\n\napplication/xml; charset=UTF-8\n\n#{x_amz_date}\n#{resource}?uploadId=2~iCw_lDY8VoNw.OB-Pk",
      ].each do |to_sign|
        get :generate_multipart_signature, params: { to_sign: }

        expect(response).to be_successful
        expect(response.body).to eq(Utilities.sign_with_aws_secret_key(to_sign))
      end
    end

    it "doesn't allow sellers to sign request for buckets they do not own" do
      expect_unauthorized("POST\n\nvideo/quicktime; charset=UTF-8\n\nx-amz-acl:private\n#{x_amz_date}\n#{resource.sub(seller.external_id, "#{seller.external_id}invalid")}?uploads")
      expect_unauthorized("POST\n\nvideo/quicktime; charset=UTF-8\n\nx-amz-acl:private\n#{x_amz_date}\n#{resource.sub(S3_BUCKET, "#{S3_BUCKET}-other")}?uploads")
    end

    it "doesn't allow if an attacker splits the request with newlines" do
      expect_unauthorized("GET /?response-content-type=\n/#{S3_BUCKET}/attachments/#{seller.external_id}/test")
    end

    it "refuses a policy document" do
      expect_unauthorized(Base64.strict_encode64({ expiration: "2030-01-01T00:00:00Z", conditions: [] }.to_json))
    end

    it "refuses a string with no resource" do
      expect_unauthorized("anything")
    end

    it "refuses a plain PUT of an object, even under the seller's own folder" do
      expect_unauthorized("PUT\n\ntext/html; charset=UTF-8\n\n#{x_amz_date}\n#{resource}")
    end

    it "refuses a resource that climbs out of the seller's folder" do
      expect_unauthorized("POST\n\n\n\nx-amz-acl:private\n#{x_amz_date}\n/#{S3_BUCKET}/attachments/#{seller.external_id}/../../other/file.mov?uploads")
    end

    it "refuses a request with headers or lines Evaporate does not send" do
      expect_unauthorized("POST\n\n\n\nx-amz-acl:public-read\n#{x_amz_date}\n#{resource}?uploads")
      expect_unauthorized("POST\n\n\n\nx-amz-acl:private\n#{x_amz_date}\n#{resource}?uploads\n")
      expect_unauthorized("POST\r\n\n\n\nx-amz-acl:private\n#{x_amz_date}\n#{resource}?uploads")
      expect_unauthorized("PUT\n\n\n\n#{x_amz_date}\n#{resource}?partNumber=1&uploadId=abc&x-id=PutObject")
    end

    it "returns a 400 when the to_sign parameter is absent" do
      get :generate_multipart_signature

      expect(response).to be_bad_request
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["error"]).to eq("Missing required parameter: to_sign")
    end

    it "returns a 400 when the to_sign parameter is not a string" do
      get :generate_multipart_signature, params: { to_sign: ["x"] }

      expect(response).to be_bad_request
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["error"]).to eq("Invalid parameter: to_sign")
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

    it "404s when the key parameter is not a string" do
      expect do
        get :cdn_url_for_blob, params: { key: { "a" => "b" } }
      end.to raise_error(ActionController::RoutingError)
    end

    it "404s when the key parameter is an array" do
      expect do
        get :cdn_url_for_blob, params: { key: ["x"] }
      end.to raise_error(ActionController::RoutingError)
    end

    it "returns the blob cdn url in JSON format" do
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")

      get :cdn_url_for_blob, params: { key: blob.key }, format: :json

      expect(response.parsed_body["url"]).to eq(cdn_url_for(blob.url))
    end
  end
end
