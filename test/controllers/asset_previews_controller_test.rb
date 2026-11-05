# frozen_string_literal: true

require "test_helper"

# The product editor's upload surface: a seller (or an admin team member acting for one) attaches
# a blob that was already uploaded directly to storage, identified by its signed_blob_id.
class AssetPreviewsControllerTest < ActionController::TestCase
  tests AssetPreviewsController

  setup do
    ActiveStorage::Current.stubs(:url_options).returns(protocol: "https", host: "localhost", port: nil)

    @seller = create_user(name: "Seller", payment_address: "seller-pay-#{unique_suffix}@example.com")
    @logged_in_user = create_user
    create_team_membership(user: @logged_in_user, seller: @seller, role: TeamMembership::ROLE_ADMIN)
    cookies.encrypted[:current_seller_id] = @seller.id
    sign_in @logged_in_user

    @product = create_product(user: @seller)
  end

  test "POST create attaches the signed blob and returns the created preview" do
    assert_difference -> { AssetPreview.count }, 1 do
      post :create, params: { link_id: @product.unique_permalink, asset_preview: { signed_blob_id: image_blob.signed_id } }, as: :json
    end

    assert_response :ok
    assert_equal true, response.parsed_body["success"]
  end

  test "POST create returns an error when the file is not found in storage" do
    ActiveStorage::Blob.any_instance.stubs(:analyze).raises(ActiveStorage::FileNotFoundError)

    assert_no_difference -> { AssetPreview.count } do
      post :create, params: { link_id: @product.unique_permalink, asset_preview: { signed_blob_id: image_blob.signed_id } }, as: :json
    end

    assert_response :ok
    assert_equal({ "success" => false, "error" => "Could not process your preview, please try again." }, response.parsed_body)
  end

  test "POST create returns an error when the blob's object is missing from storage before the save" do
    ActiveStorage::Attached::One.any_instance.stubs(:attach).raises(ActiveStorage::FileNotFoundError)

    assert_no_difference -> { AssetPreview.count } do
      post :create, params: { link_id: @product.unique_permalink, asset_preview: { signed_blob_id: image_blob.signed_id } }, as: :json
    end

    assert_response :ok
    assert_equal({ "success" => false, "error" => "Could not process your preview, please try again." }, response.parsed_body)
  end

  test "POST create returns an error when the blob is purged before the attach completes" do
    ActiveStorage::Attached::One.any_instance.stubs(:attach).raises(
      ActiveRecord::InvalidForeignKey.new("Cannot add or update a child row: a foreign key constraint fails")
    )

    assert_no_difference -> { AssetPreview.count } do
      post :create, params: { link_id: @product.unique_permalink, asset_preview: { signed_blob_id: image_blob.signed_id } }, as: :json
    end

    assert_response :ok
    assert_equal({ "success" => false, "error" => "Could not process your preview, please try again." }, response.parsed_body)
  end

  private
    def image_blob
      @image_blob ||= ActiveStorage::Blob.create_and_upload!(
        io: fixture_file_upload("Austin's Mojo.png", "image/png"), filename: "Austin's Mojo.png"
      )
    end
end
