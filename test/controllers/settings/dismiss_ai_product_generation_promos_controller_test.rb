# frozen_string_literal: true

require "test_helper"
require "support/controller_seller_auth_helpers"

class Settings::DismissAiProductGenerationPromosControllerTest < ActionController::TestCase
  include Devise::Test::ControllerHelpers
  include ControllerSellerAuthHelpers

  setup do
    @seller = users(:named_seller)
    @admin = users(:admin_for_named_seller)
    sign_in_as_seller(@admin, @seller)
    Feature.activate(:ai_product_generation)
    # Bypass eligibility chain (sales_cents_total + has_completed_payouts? both hit
    # external/ES surfaces in the Minitest lane).
    # Capture+restore via UnboundMethod — `eligible_for_ai_product_generation?`
    # is defined directly on User, so `remove_method` would strip the real
    # implementation and leak NameError into sibling tests.
    @orig_eligible = User.instance_method(:eligible_for_ai_product_generation?) if User.method_defined?(:eligible_for_ai_product_generation?)
    User.define_method(:eligible_for_ai_product_generation?) { true }
  end

  teardown do
    if @orig_eligible
      User.define_method(:eligible_for_ai_product_generation?, @orig_eligible)
    elsif User.instance_methods(false).include?(:eligible_for_ai_product_generation?)
      User.remove_method(:eligible_for_ai_product_generation?)
    end
    restore_protect_against_forgery!
  end

  test "POST create dismisses the AI product generation promo alert" do
    refute @seller.dismissed_create_products_with_ai_promo_alert
    post :create
    assert_response :ok
    assert @seller.reload.dismissed_create_products_with_ai_promo_alert
  end

  test "POST create is idempotent when already dismissed" do
    @seller.update!(dismissed_create_products_with_ai_promo_alert: true)
    post :create
    assert_response :ok
    assert @seller.reload.dismissed_create_products_with_ai_promo_alert
  end
end
