# frozen_string_literal: true

require "test_helper"

# Ported from spec/controllers/api/v2/thumbnails_controller_spec.rb (#5801).
# First API v2 controller port: authenticates with Doorkeeper OAuth access
# tokens passed as the `access_token` param (no Devise sign-in), and asserts on
# the JSON response body. The two "authorized oauth v1 api method" shared
# examples are inlined as explicit unauthenticated (401) and wrong-scope (403)
# tests, matching spec/shared_examples/authorized_oauth_v1_api_method.rb.
class Api::V2::ThumbnailsControllerTest < ActionController::TestCase
  tests Api::V2::ThumbnailsController

  setup do
    # The Minitest harness swaps ActiveStorage's default service for a local Disk
    # service, whose #url needs ActiveStorage::Current.url_options. This API
    # controller doesn't include ActiveStorage::SetCurrent (unlike the request
    # stack), and the value test_helper sets in setup is cleared when the
    # controller test processes the request, so the thumbnail JSON's URL blows up.
    # (The RSpec suite dodged this by using the S3 service, which needs no
    # url_options.) Stub the reader so it survives the per-request reset.
    ActiveStorage::Current.stubs(:url_options).returns(protocol: "https", host: "localhost", port: nil)

    @user = create_user
    @app = create_oauth_application(owner: create_user)
    @product = create_product(user: @user)
  end

  # --- POST create ------------------------------------------------------------

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

  test "POST create attaches a thumbnail from signed_blob_id" do
    blob = uploaded_blob("smilie.png")

    post :create, params: edit_products_params(signed_blob_id: blob.signed_id)

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["success"]
    assert body["thumbnail"].present?
    assert body["thumbnail"]["guid"].present?
    assert @product.reload.thumbnail.alive?
  end

  test "POST create attaches a thumbnail from a URL" do
    url = "https://example.com/assets/thumbnail.png?token=abc&w=600"
    response_double = remote_file_response("smilie.png", "image/png")
    # `expects` both stubs SsrfFilter.get and verifies it was called with the URL
    # (the spec's `expect(SsrfFilter).to have_received(:get).with(url)`).
    SsrfFilter.expects(:get).with(url).yields(response_double).returns(response_double)

    post :create, params: edit_products_params(url:)

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["success"]
    assert body["thumbnail"]["url"].present?
    assert body["thumbnail"]["guid"].present?
    assert @product.reload.thumbnail.alive?
    assert_equal "thumbnail.png", @product.thumbnail.file.blob.filename.to_s
    assert_equal({ "width" => 1006, "height" => 1006 }, @product.thumbnail.file.blob.metadata.slice("width", "height"))
    assert_nil @product.thumbnail.unsplash_url
  end

  test "POST create replaces an existing thumbnail" do
    existing = create_thumbnail(product: @product)
    old_guid = existing.guid
    blob = uploaded_blob("smilie.png")

    post :create, params: edit_products_params(signed_blob_id: blob.signed_id)

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["success"]
    assert_equal old_guid, @product.reload.thumbnail.guid
    assert @product.thumbnail.alive?
  end

  test "POST create replaces an existing thumbnail from a URL" do
    existing = create_thumbnail(product: @product)
    old_guid = existing.guid
    old_blob = existing.file.blob
    url = "https://example.com/replacement.png"
    stub_remote_file(url, "smilie.png", "image/png")

    assert_no_difference -> { Thumbnail.count } do
      post :create, params: edit_products_params(url:)
    end

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["success"]
    assert_equal old_guid, @product.reload.thumbnail.guid
    assert_not_equal old_blob, @product.thumbnail.file.blob
    assert_equal "replacement.png", @product.thumbnail.file.blob.filename.to_s
  end

  test "POST create returns validation errors for invalid files" do
    blob = uploaded_blob("kFDzu.png")

    post :create, params: edit_products_params(signed_blob_id: blob.signed_id)

    body = response.parsed_body
    assert_equal false, body["success"]
    assert body["message"].present?
  end

  test "POST create returns validation errors for too-small remote files" do
    url = "https://example.com/small.png"
    stub_remote_file(url, "test-small.png", "image/png")

    post :create, params: edit_products_params(url:)

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Could not process your thumbnail, please try again.", body["message"]
    assert_nil @product.reload.thumbnail
  end

  test "POST create returns validation errors for non-square remote files" do
    url = "https://example.com/non-square.png"
    stub_remote_file(url, "kFDzu.png", "image/png")

    post :create, params: edit_products_params(url:)

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Please upload a square thumbnail.", body["message"]
    assert_nil @product.reload.thumbnail
  end

  test "POST create returns validation errors for oversized remote files and purges the downloaded blob" do
    url = "https://example.com/large.jpeg"
    stub_remote_file(url, "error_file.jpeg", "image/jpeg")

    assert_no_difference -> { ActiveStorage::Blob.count } do
      post :create, params: edit_products_params(url:)
    end

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Could not process your thumbnail, please upload an image with size smaller than 5 MB.", body["message"]
    assert_nil @product.reload.thumbnail
  end

  test "POST create rejects remote files with content length above the thumbnail limit before creating a blob" do
    url = "https://example.com/large.jpeg"
    stub_remote_file(url, "smilie.png", "image/jpeg", content_length: Thumbnail::MAX_FILE_SIZE + 1)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      post :create, params: edit_products_params(url:)
    end

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Could not process your thumbnail, please upload an image with size smaller than 5 MB.", body["message"]
    assert_nil @product.reload.thumbnail
  end

  test "POST create stops downloading remote files when the streamed body exceeds the thumbnail limit" do
    url = "https://example.com/large.jpeg"
    stub_remote_file(url, "smilie.png", "image/jpeg", chunks: ["a" * Thumbnail::MAX_FILE_SIZE, "a"])

    assert_no_difference -> { ActiveStorage::Blob.count } do
      post :create, params: edit_products_params(url:)
    end

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Could not process your thumbnail, please upload an image with size smaller than 5 MB.", body["message"]
    assert_nil @product.reload.thumbnail
  end

  test "POST create stops downloading redirect response bodies when they exceed the thumbnail limit" do
    url = "https://example.com/redirecting-thumbnail.png"
    redirect_response = remote_file_response("blah.txt", "text/plain", chunks: ["a" * Thumbnail::MAX_FILE_SIZE, "a"], redirect: true)
    final_response = remote_file_response("smilie.png", "image/png")
    SsrfFilter.stubs(:get).with(url).multiple_yields([redirect_response], [final_response]).returns(final_response)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      post :create, params: edit_products_params(url:)
    end

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Could not process your thumbnail, please upload an image with size smaller than 5 MB.", body["message"]
    assert_nil @product.reload.thumbnail
  end

  test "POST create does not count discarded redirect response bodies against the final image size" do
    url = "https://example.com/redirecting-thumbnail.png"
    redirect_response = remote_file_response("blah.txt", "text/plain", chunks: ["a" * Thumbnail::MAX_FILE_SIZE], redirect: true)
    final_response = remote_file_response("smilie.png", "image/png")
    SsrfFilter.stubs(:get).with(url).multiple_yields([redirect_response], [final_response]).returns(final_response)

    post :create, params: edit_products_params(url:)

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["success"]
    assert @product.reload.thumbnail.alive?
    assert_equal "redirecting-thumbnail.png", @product.thumbnail.file.blob.filename.to_s
    assert_equal File.size(Rails.root.join("spec", "support", "fixtures", "smilie.png")), @product.thumbnail.file.blob.byte_size
  end

  test "POST create purges the downloaded blob and keeps the existing thumbnail when analysis fails" do
    existing = create_thumbnail(product: @product)
    old_blob = existing.file.blob
    url = "https://example.com/thumbnail.png"
    stub_remote_file(url, "smilie.png", "image/png")
    ActiveStorage::Blob.any_instance.stubs(:analyze).raises(Net::ReadTimeout)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      post :create, params: edit_products_params(url:)
    end

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Could not process your thumbnail, please try again.", body["message"]
    assert_equal old_blob, @product.reload.thumbnail.file.blob
  end

  test "POST create returns processing errors for non-success remote responses without creating a blob" do
    url = "https://example.com/not-found.png"
    stub_remote_file(url, "blah.txt", "text/html", response_class: Net::HTTPNotFound)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      post :create, params: edit_products_params(url:)
    end

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Could not process your thumbnail, please try again.", body["message"]
    assert_nil @product.reload.thumbnail
  end

  test "POST create returns processing errors for non-image remote files" do
    url = "https://example.com/not-image.txt"
    stub_remote_file(url, "blah.txt", "text/plain")

    post :create, params: edit_products_params(url:)

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Could not process your thumbnail, please try again.", body["message"]
    assert_nil @product.reload.thumbnail
  end

  test "POST create returns error when neither signed_blob_id nor url is provided" do
    post :create, params: edit_products_params

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Please provide a signed_blob_id or url.", body["message"]
  end

  test "POST create returns error for invalid signed_blob_id" do
    post :create, params: edit_products_params(signed_blob_id: "invalid-blob-id")

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "The signed_blob_id is invalid or expired.", body["message"]
  end

  test "POST create returns error for invalid URLs" do
    post :create, params: edit_products_params(url: "ftp://example.com/thumbnail.png")

    assert_response :bad_request
    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Please provide a valid public image URL.", body["message"]
  end

  test "POST create returns error for unresolved URLs" do
    url = "https://nonexistent.example.com/thumbnail.png"
    SsrfFilter.stubs(:get).with(url).raises(SsrfFilter::UnresolvedHostname)

    post :create, params: edit_products_params(url:)

    assert_response :bad_request
    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Please provide a valid public image URL.", body["message"]
  end

  test "POST create returns error for URLs with too many redirects" do
    url = "https://example.com/redirect-loop.png"
    SsrfFilter.stubs(:get).with(url).raises(SsrfFilter::TooManyRedirects)

    post :create, params: edit_products_params(url:)

    assert_response :bad_request
    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Please provide a valid public image URL.", body["message"]
  end

  test "POST create returns error for blocked internal URLs" do
    url = "http://127.0.0.1/thumbnail.png"
    SsrfFilter.stubs(:get).with(url).raises(SsrfFilter::PrivateIPAddress)

    post :create, params: edit_products_params(url:)

    assert_response :bad_request
    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Please provide a valid public image URL.", body["message"]
  end

  test "POST create returns processing errors when the remote file cannot be downloaded" do
    url = "https://example.com/missing.png"
    SsrfFilter.stubs(:get).with(url).raises(SocketError)

    post :create, params: edit_products_params(url:)

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "Could not process your thumbnail, please try again.", body["message"]
  end

  test "POST create revives a previously deleted thumbnail" do
    thumbnail = create_thumbnail(product: @product)
    thumbnail.mark_deleted!
    assert_not @product.reload.thumbnail.alive?

    blob = uploaded_blob("smilie.png")

    post :create, params: edit_products_params(signed_blob_id: blob.signed_id)

    assert_response :success
    assert @product.reload.thumbnail.alive?
  end

  test "POST create grants access with the account scope" do
    blob = uploaded_blob("smilie.png")

    token = create_doorkeeper_access_token(application: @app, resource_owner_id: @user.id, scopes: "account")
    post :create, params: { link_id: @product.external_id, access_token: token.token, signed_blob_id: blob.signed_id }

    assert_response :success
  end

  # --- DELETE destroy ---------------------------------------------------------

  test "DELETE destroy errors out when the request is not authenticated" do
    create_thumbnail(product: @product)

    get :destroy, params: { link_id: @product.external_id }

    assert_equal 401, response.status
    assert_empty response.body.strip
  end

  test "DELETE destroy errors out for a token without the edit_products scope" do
    create_thumbnail(product: @product)
    token = create_doorkeeper_access_token(application: @app, resource_owner_id: @user.id, scopes: "view_public view_sales")

    get :destroy, params: { link_id: @product.external_id, access_token: token.token }

    assert_equal 403, response.status
    assert_empty response.body.strip
  end

  test "DELETE destroy deletes the thumbnail" do
    create_thumbnail(product: @product)

    delete :destroy, params: edit_products_params

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["success"]
    assert_not @product.reload.thumbnail.alive?
  end

  test "DELETE destroy returns error when no thumbnail exists" do
    thumbnail = create_thumbnail(product: @product)
    thumbnail.mark_deleted!

    delete :destroy, params: edit_products_params

    body = response.parsed_body
    assert_equal false, body["success"]
    assert_equal "The thumbnail was not found.", body["message"]
  end

  private
    # Params carrying an edit_products-scoped token for the standard user, the
    # scope the create/destroy actions require.
    def edit_products_params(extra = {})
      token = create_doorkeeper_access_token(application: @app, resource_owner_id: @user.id, scopes: "edit_products")
      { link_id: @product.external_id, access_token: token.token }.merge(extra)
    end

    def uploaded_blob(fixture_name)
      blob = ActiveStorage::Blob.create_and_upload!(
        io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", fixture_name), "image/png"),
        filename: fixture_name
      )
      blob.analyze
      blob
    end

    def stub_remote_file(url, fixture_name, content_type, content_length: nil, chunks: nil, response_class: Net::HTTPOK)
      response = remote_file_response(fixture_name, content_type, content_length:, chunks:, response_class:)
      SsrfFilter.stubs(:get).with(url).yields(response).returns(response)
    end

    def remote_file_response(fixture_name, content_type, content_length: nil, chunks: nil, response_class: Net::HTTPOK, redirect: false)
      response_class = Net::HTTPRedirection if redirect

      Class.new(response_class) do
        define_method(:initialize) do |fixture_name, content_type, content_length, chunks|
          if is_a?(Net::HTTPResponse)
            code = redirect ? "302" : Net::HTTPResponse::CODE_TO_OBJ.key(response_class)
            super("1.1", code, code)
          end

          @body = File.binread(Rails.root.join("spec", "support", "fixtures", fixture_name))
          @content_type = content_type
          @content_length = content_length
          @chunks = chunks
        end

        attr_reader :content_type

        def [](header)
          @content_length if header.downcase == "content-length"
        end

        def read_body
          (@chunks || [@body]).each { yield _1 }
        end
      end.new(fixture_name, content_type, content_length, chunks)
    end
end
