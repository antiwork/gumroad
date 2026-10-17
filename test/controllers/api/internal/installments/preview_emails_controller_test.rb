# frozen_string_literal: true

require "test_helper"

class Api::Internal::Installments::PreviewEmailsControllerTest < ActionController::TestCase
  tests Api::Internal::Installments::PreviewEmailsController

  setup do
    @seller = create_user
    @admin = create_user
    create_team_membership(user: @admin, seller: @seller, role: TeamMembership::ROLE_ADMIN)
    cookies.encrypted[:current_seller_id] = @seller.id
    sign_in @admin
  end

  test "POST create returns 404 for an id that matches no live post of the seller" do
    post :create, params: { id: "not-a-real-id" }

    assert_equal 404, response.status
    assert_equal({ "success" => false, "error" => "Not found" }, JSON.parse(response.body))
  end

  test "POST create returns 404 for another seller's post" do
    other_seller = create_user
    other_post = create_installment(seller: other_seller, link: create_product(user: other_seller))

    post :create, params: { id: other_post.external_id }

    assert_equal 404, response.status
  end

  test "POST create previews the post for an admin of the seller" do
    post_record = create_installment(seller: @seller)
    PostEmailApi.expects(:process).once

    post :create, params: { id: post_record.external_id }

    assert_equal 200, response.status
  end
end
