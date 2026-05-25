# frozen_string_literal: true

require "test_helper"
require "support/controller_seller_auth_helpers"

class ReviewsControllerTest < ActionController::TestCase
  include Devise::Test::ControllerHelpers
  include ControllerSellerAuthHelpers

  setup do
    @user = users(:purchaser)
    sign_in_as_seller(@user)
    Feature.activate(:reviews_page)
    @request.headers["X-Inertia"] = "true"
  end

  teardown do
    Feature.deactivate(:reviews_page)
    restore_protect_against_forgery!
  end

  test "GET index renders Reviews/Index with reviews + purchases props" do
    get :index
    assert_response :success
    page = JSON.parse(@response.body)
    assert_equal "Reviews/Index", page["component"]
    assert_kind_of Array, page["props"]["reviews"]
    assert_kind_of Array, page["props"]["purchases"]
    assert_includes [true, false], page["props"]["following_wishlists_enabled"]
  end
end
