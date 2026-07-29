# frozen_string_literal: true

require "test_helper"

# Ported from spec/controllers/api/v2/covers_controller_spec.rb (#5801).
# Same shape as the api/v2 thumbnails port: Doorkeeper OAuth tokens in the
# `access_token` param rather than a Devise sign-in, and assertions on the JSON
# body. The four "authorized oauth v1 api method" shared examples are inlined as
# explicit unauthenticated (401) and wrong-scope (403) tests per action, matching
# spec/shared_examples/authorized_oauth_v1_api_method.rb.
class Api::V2::CoversControllerTest < ActionController::TestCase
  tests Api::V2::CoversController

  setup do
    # The Disk service test_helper installs needs url_options to build blob URLs,
    # and this API controller doesn't include ActiveStorage::SetCurrent, so the
    # value set in test_helper's setup is cleared when the request is processed.
    # (See the same note in api/v2/thumbnails_controller_test.rb.)
    ActiveStorage::Current.stubs(:url_options).returns(protocol: "https", host: "localhost", port: nil)

    @user = create_user
    @app = create_oauth_application(owner: create_user)
    @product = create_product(user: @user)
  end

  # --- POST create -----------------------------------------------------------

  test "POST create errors out when the request is not authenticated" do
    get :create, params: { link_id: @product.external_id }

    assert_equal 401, response.status
    assert_empty response.body.strip
  end

  test "POST create errors out for a token without the edit_products scope" do
    token = create_doorkeeper_access_token(application: @app, resource_owner_id: @user.id, scopes: "view_public view_sales")
    get :create, params: { link_id: @product.external_id, access_token: token.token }

    assert_equal 403, response.status
    assert_empty response.body.strip
  end

  test "POST create adds a file-based cover from signed_blob_id" do
    post :create, params: create_params(signed_blob_id: uploaded_cover_blob.signed_id)

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["success"]
    assert_kind_of Array, body["covers"]
    assert_equal 1, body["covers"].length
    assert body["main_cover_id"].present?
    assert_equal 1, @product.reload.asset_previews.alive.count
  end

  test "POST create adds a URL-based cover" do
    VCR.use_cassette("Api_V2_CoversController/POST_create_/when_logged_in_with_edit_products_scope/adds_a_URL-based_cover") do
      post :create, params: create_params(url: "https://www.youtube.com/watch?v=qKebcV1jv3A")
    end

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["success"]
    assert_kind_of Array, body["covers"]
    assert_equal 1, body["covers"].length
    assert_equal 1, @product.reload.asset_previews.alive.count
  end

  test "POST create returns an error for an invalid signed_blob_id" do
    post :create, params: create_params(signed_blob_id: "invalid-blob-id")

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "The signed_blob_id is invalid or expired.", body["message"]
  end

  test "POST create returns a descriptive error for an unsupported file type" do
    post :create, params: create_params(signed_blob_id: uploaded_cover_blob("webp_image.webp", "image/webp").signed_id)

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Cover must be an image (JPEG, PNG, GIF) or a video.", body["message"]
  end

  test "POST create returns the existing main_cover_id when covers already exist" do
    existing_cover = create_asset_preview(link: @product)

    post :create, params: create_params(signed_blob_id: uploaded_cover_blob.signed_id)

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["success"]
    assert_equal 2, body["covers"].length
    assert_equal existing_cover.guid, body["main_cover_id"]
  end

  test "POST create returns an error when neither signed_blob_id nor url is provided" do
    post :create, params: create_params

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Please provide a signed_blob_id or url.", body["message"]
  end

  test "POST create respects the maximum cover count" do
    Link::MAX_PREVIEW_COUNT.times { create_asset_preview(link: @product) }

    post :create, params: create_params(signed_blob_id: uploaded_cover_blob.signed_id)

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_includes body["message"], "limit of #{Link::MAX_PREVIEW_COUNT} previews"
  end

  test "POST create grants access with the account scope" do
    token = create_doorkeeper_access_token(application: @app, resource_owner_id: @user.id, scopes: "account")
    post :create, params: { link_id: @product.external_id, access_token: token.token, signed_blob_id: uploaded_cover_blob.signed_id }

    assert_response :success
  end

  # --- DELETE destroy --------------------------------------------------------

  test "DELETE destroy errors out when the request is not authenticated" do
    cover = create_asset_preview(link: @product)
    get :destroy, params: { link_id: @product.external_id, id: cover.guid }

    assert_equal 401, response.status
    assert_empty response.body.strip
  end

  test "DELETE destroy errors out for a token without the edit_products scope" do
    cover = create_asset_preview(link: @product)
    token = create_doorkeeper_access_token(application: @app, resource_owner_id: @user.id, scopes: "view_public view_sales")
    get :destroy, params: { link_id: @product.external_id, id: cover.guid, access_token: token.token }

    assert_equal 403, response.status
    assert_empty response.body.strip
  end

  test "DELETE destroy deletes the cover" do
    cover = create_asset_preview(link: @product)

    delete :destroy, params: create_params(id: cover.guid)

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["success"]
    assert_kind_of Array, body["covers"]
    assert_equal 0, body["covers"].length
    assert_equal 0, @product.reload.asset_previews.alive.count
  end

  test "DELETE destroy returns the remaining covers and main_cover_id" do
    cover = create_asset_preview(link: @product)
    second_cover = create_asset_preview(link: @product)

    delete :destroy, params: create_params(id: cover.guid)

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["success"]
    assert_equal 1, body["covers"].length
    assert_equal second_cover.guid, body["main_cover_id"]
  end

  test "DELETE destroy returns an error when the cover is not found" do
    create_asset_preview(link: @product)

    delete :destroy, params: create_params(id: "nonexistent")

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "The cover was not found.", body["message"]
  end

  private
    # The product plus an edit_products token, which every non-authorization test
    # here sends.
    def create_params(**attrs)
      token = create_doorkeeper_access_token(application: @app, resource_owner_id: @user.id, scopes: "edit_products")
      { link_id: @product.external_id, access_token: token.token }.merge(attrs)
    end

    def uploaded_cover_blob(filename = "kFDzu.png", content_type = "image/png")
      blob = ActiveStorage::Blob.create_and_upload!(
        io: Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures", filename), content_type),
        filename:
      )
      blob.analyze
      blob
    end
end
