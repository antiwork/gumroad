# frozen_string_literal: true

require "test_helper"
require "support/controller_seller_auth_helpers"

class S3UtilityControllerTest < ActionController::TestCase
  include Devise::Test::ControllerHelpers
  include ControllerSellerAuthHelpers
  include CdnUrlHelper

  setup do
    @seller = users(:named_seller)
    @seller.save! if @seller.external_id.blank?
    @admin = users(:admin_for_named_seller)
    @admin.save! if @admin.external_id.blank?
    sign_in_as_seller(@admin, @seller)
  end

  teardown { restore_protect_against_forgery! }

  test "generate_multipart_signature forbids signing for buckets seller doesn't own" do
    bogus = @seller.external_id + "invalid"
    sign_string = "POST\n\nvideo/quicktime; charset=UTF-8\n\nx-amz-acl:private\nx-amz-date:Mon, 02 Mar 2015 17:21:19 GMT\n/#{S3_BUCKET}/attachments/#{bogus}/bf03/original/foo.mov?uploads"
    get :generate_multipart_signature, params: { to_sign: sign_string }
    assert_response :forbidden
    assert_equal false, @response.parsed_body["success"]
  end

  test "generate_multipart_signature forbids when attacker splits with newlines" do
    sign_string = "GET /?response-content-type=\n/#{S3_BUCKET}/attachments/#{@seller.external_id}/test"
    get :generate_multipart_signature, params: { to_sign: sign_string }
    assert_response :forbidden
    assert_equal false, @response.parsed_body["success"]
  end

  test "generate_multipart_signature allows seller to sign for owned buckets" do
    sign_string = "POST\n\nvideo/quicktime; charset=UTF-8\n\nx-amz-acl:private\nx-amz-date:Mon, 02 Mar 2015 17:21:19 GMT\n/#{S3_BUCKET}/attachments/#{@seller.external_id}/bf03/original/foo.mov?uploads"
    get :generate_multipart_signature, params: { to_sign: sign_string }
    assert_response :success
  end

  test "cdn_url_for_blob returns blob cdn url with valid key" do
    skip "ActiveStorage::Blob.create_and_upload! hits the live S3 endpoint (MinIO :9000) which CI doesn't carry; no S3 stub harness in the Minitest lane."
    blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
    get :cdn_url_for_blob, params: { key: blob.key }
    assert_redirected_to cdn_url_for(blob.url)
  end

  test "cdn_url_for_blob 404s with an invalid key" do
    assert_raises(ActionController::RoutingError) do
      get :cdn_url_for_blob, params: { key: "xxx-#{SecureRandom.hex(4)}" }
    end
  end

  test "cdn_url_for_blob returns the blob cdn url in JSON format" do
    skip "ActiveStorage::Blob.create_and_upload! hits the live S3 endpoint (MinIO :9000) which CI doesn't carry; no S3 stub harness in the Minitest lane."
    blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
    get :cdn_url_for_blob, params: { key: blob.key }, format: :json
    assert_equal cdn_url_for(blob.url), @response.parsed_body["url"]
  end
end
