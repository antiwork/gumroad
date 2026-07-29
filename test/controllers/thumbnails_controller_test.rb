# frozen_string_literal: true

require "test_helper"

# Ported from spec/controllers/thumbnails_controller_spec.rb (#5801).
# A seller-area controller: the logged-in user is an admin team member acting for
# the seller, matching the "with user signed in as admin for seller" shared
# context. The three "authorize called for action" shared examples and the
# "inherits from Sellers::BaseController" one are inlined below.
class ThumbnailsControllerTest < ActionController::TestCase
  tests ThumbnailsController

  setup do
    # Thumbnail#as_json builds a blob URL, and the Disk service test_helper
    # installs needs url_options for that. ActiveStorage::Current is a
    # per-request CurrentAttribute that gets reset when a controller test
    # processes the request, so stub the reader rather than assigning it. (Same
    # note as api/v2/thumbnails_controller_test.rb; the middleware that would set
    # it doesn't run in ActionController::TestCase.)
    ActiveStorage::Current.stubs(:url_options).returns(protocol: "https", host: "localhost", port: nil)

    @seller = create_user(name: "Seller", payment_address: "seller-pay-#{unique_suffix}@example.com")
    @logged_in_user = create_user
    create_team_membership(user: @logged_in_user, seller: @seller, role: TeamMembership::ROLE_ADMIN)
    cookies.encrypted[:current_seller_id] = @seller.id
    sign_in @logged_in_user

    @product = create_product(user: @seller)
  end

  test "inherits from Sellers::BaseController" do
    assert_includes ThumbnailsController.ancestors, Sellers::BaseController
  end

  # --- POST create -----------------------------------------------------------

  test "POST create calls authorize with the Thumbnail policy" do
    assert_authorize_called(:post, :create, params: { link_id: @product.unique_permalink, thumbnail: { signed_blob_id: image_blob.signed_id } })
  end

  test "POST create raises RoutingError when the signed-in user is not the owner" do
    sign_in create_user

    assert_no_difference -> { Thumbnail.count } do
      assert_raises(ActionController::RoutingError, "Not Found") do
        post :create, params: { link_id: @product.unique_permalink, thumbnail: { signed_blob_id: image_blob.signed_id } }
      end
    end
  end

  test "POST create returns an error when thumbnail is a raw file upload instead of signed_blob_id" do
    assert_no_difference -> { Thumbnail.count } do
      post :create, params: { link_id: @product.unique_permalink, thumbnail: fixture_file_upload("Austin's Mojo.png", "image/png"), format: :json }
    end

    assert_equal 400, response.status
    assert_equal({ "success" => false, "error" => "Invalid thumbnail parameter. Expected signed_blob_id." }, response.parsed_body)
  end

  test "POST create fails for a thumbnail that is not square" do
    assert_nil @product.thumbnail
    invalid_blob = ActiveStorage::Blob.create_and_upload!(
      io: fixture_file_upload("test-squashed.png", "image/png"), filename: "test-squashed.png"
    )

    assert_no_difference -> { Thumbnail.count } do
      post :create, params: { link_id: @product.unique_permalink, thumbnail: { signed_blob_id: invalid_blob.signed_id }, format: :json }
    end

    assert_nil @product.reload.thumbnail
    assert_equal 200, response.status
    assert_equal({ "success" => false, "error" => "Please upload a square thumbnail." }, response.parsed_body)
  end

  test "POST create creates a thumbnail" do
    assert_nil @product.thumbnail
    blob = image_blob

    assert_difference -> { Thumbnail.count }, 1 do
      post :create, params: { link_id: @product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id }, format: :json }
    end

    assert_equal blob, @product.reload.thumbnail.file.blob
    assert_equal 200, response.status
    assert_equal({ "success" => true, "thumbnail" => @product.thumbnail.as_json.stringify_keys }, response.parsed_body)
  end

  test "POST create modifies the thumbnail when one created from a file already exists" do
    @product.update!(thumbnail: create_thumbnail)
    blob = image_blob

    assert_no_difference -> { Thumbnail.count } do
      post :create, params: { link_id: @product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id }, format: :json }
    end

    assert_equal blob, @product.reload.thumbnail.file.blob
    assert_equal 200, response.status
    assert_equal({ "success" => true, "thumbnail" => @product.thumbnail.as_json.stringify_keys }, response.parsed_body)
  end

  test "POST create returns an error when thumbnail analysis times out" do
    ActiveStorage::Blob.any_instance.stubs(:analyze).raises(Timeout::Error)

    assert_no_difference -> { Thumbnail.count } do
      post :create, params: { link_id: @product.unique_permalink, thumbnail: { signed_blob_id: image_blob.signed_id }, format: :json }
    end

    assert_equal 200, response.status
    assert_equal({ "success" => false, "error" => "Thumbnail processing took too long, please try again with a smaller image." }, response.parsed_body)
  end

  test "POST create returns an error when the file is not found in storage" do
    ActiveStorage::Blob.any_instance.stubs(:analyze).raises(ActiveStorage::FileNotFoundError)

    assert_no_difference -> { Thumbnail.count } do
      post :create, params: { link_id: @product.unique_permalink, thumbnail: { signed_blob_id: image_blob.signed_id }, format: :json }
    end

    assert_equal 200, response.status
    assert_equal({ "success" => false, "error" => "Could not process your thumbnail, please try again." }, response.parsed_body)
  end

  test "POST create returns an error when the blob is purged before the attach completes" do
    ActiveStorage::Attached::One.any_instance.stubs(:attach).raises(
      ActiveRecord::InvalidForeignKey.new("Cannot add or update a child row: a foreign key constraint fails")
    )

    assert_no_difference -> { Thumbnail.count } do
      post :create, params: { link_id: @product.unique_permalink, thumbnail: { signed_blob_id: image_blob.signed_id }, format: :json }
    end

    assert_equal 200, response.status
    assert_equal({ "success" => false, "error" => "Could not process your thumbnail, please try again." }, response.parsed_body)
  end

  test "POST create restores a deleted thumbnail" do
    @product.update!(thumbnail: create_thumbnail)
    @product.thumbnail.mark_deleted!
    blob = image_blob

    assert_difference -> { Thumbnail.alive.count }, 1 do
      assert_no_difference -> { Thumbnail.count } do
        post :create, params: { link_id: @product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id }, format: :json }
      end
    end

    assert_not @product.reload.thumbnail.deleted?
    assert_equal blob, @product.thumbnail.file.blob
    assert_equal 200, response.status
    assert_equal({ "success" => true, "thumbnail" => @product.thumbnail.as_json.stringify_keys }, response.parsed_body)
  end

  # --- DELETE destroy --------------------------------------------------------

  test "DELETE destroy calls authorize with the Thumbnail policy" do
    thumbnail = create_thumbnail
    sign_in thumbnail.product.user

    assert_authorize_called(:delete, :destroy, params: { link_id: thumbnail.product.unique_permalink, id: thumbnail.guid })
  end

  test "DELETE destroy calls authorize when the logged-in user is an admin of the seller account" do
    thumbnail = create_thumbnail
    admin = create_user
    create_team_membership(user: admin, seller: thumbnail.product.user, role: TeamMembership::ROLE_ADMIN)
    cookies.encrypted[:current_seller_id] = thumbnail.product.user.id
    sign_in admin

    assert_authorize_called(:delete, :destroy, params: { link_id: thumbnail.product.unique_permalink, id: thumbnail.guid })
  end

  test "DELETE destroy fails when the user is not the owner" do
    thumbnail = create_thumbnail
    sign_in create_user

    assert_no_difference -> { Thumbnail.alive.count } do
      assert_raises(ActionController::RoutingError, "Not Found") do
        delete :destroy, params: { link_id: thumbnail.product.unique_permalink, id: thumbnail.guid }
      end
    end
  end

  test "DELETE destroy fails for an invalid thumbnail id" do
    thumbnail = create_thumbnail
    sign_in thumbnail.product.user

    assert_no_difference -> { Thumbnail.alive.count } do
      delete :destroy, params: { link_id: thumbnail.product.unique_permalink, id: "invalid_id" }
    end

    assert_equal 200, response.status
    assert_equal({ "success" => false }, response.parsed_body)
  end

  test "DELETE destroy removes the thumbnail" do
    thumbnail = create_thumbnail
    sign_in thumbnail.product.user
    product = thumbnail.product

    assert_difference -> { Thumbnail.alive.count }, -1 do
      delete :destroy, params: { link_id: product.unique_permalink, id: thumbnail.guid }
    end

    assert product.reload.thumbnail.deleted?
    assert_equal 200, response.status
    assert_equal({ "success" => true, "thumbnail" => product.thumbnail.as_json.stringify_keys }, response.parsed_body)
  end

  private
    # A square image blob, which is what the thumbnail validation accepts.
    def image_blob
      @image_blob ||= ActiveStorage::Blob.create_and_upload!(
        io: fixture_file_upload("Austin's Mojo.png", "image/png"), filename: "Austin's Mojo.png"
      )
    end

    # Replaces the RSpec `it_behaves_like "authorize called for action"`: stub the
    # policy so every ThumbnailPolicy.new is recorded, then assert one was built
    # with the controller's pundit_user and the Thumbnail class.
    def assert_authorize_called(verb, action, params:)
      calls = []
      ThumbnailPolicy.stubs(:new).with do |context, record|
        calls << [context, record]
        true
      end.returns(stub("ThumbnailPolicy", "#{action}?": false))

      public_send(verb, action, params:)

      assert(calls.any? { |context, record| context == @controller.send(:pundit_user) && record == Thumbnail },
             "Expected ThumbnailPolicy to be built via `authorize` with the controller's pundit_user and Thumbnail")
    end
end
