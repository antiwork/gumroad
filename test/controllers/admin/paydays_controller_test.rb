# frozen_string_literal: true

require "test_helper"

class Admin::PaydaysControllerTest < ActionController::TestCase
  include Devise::Test::ControllerHelpers

  setup do
    @admin = users(:admin_user)
    @user = users(:named_seller)
    @user.save! if @user.external_id.blank?
    sign_in @admin
    @orig_protect = ActionController::Base.instance_method(:protect_against_forgery?)
    ActionController::Base.define_method(:protect_against_forgery?) { false }
  end

  teardown do
    ActionController::Base.define_method(:protect_against_forgery?, @orig_protect) if @orig_protect
  end

  test "inherits from Admin::BaseController" do
    assert_includes Admin::PaydaysController.ancestors, Admin::BaseController
  end

  test "POST pay_user raises for unknown user external_id" do
    assert_raises(ActiveRecord::RecordNotFound) do
      post :pay_user, params: { id: "not-a-real-id", payday: { payout_period_end_date: "2024-01-01", payout_processor: PayoutProcessorType::STRIPE } }
    end
  end

  test "POST pay_user with no created payments redirects with 'Payment was not sent.' notice" do
    # Capture the original UnboundMethod and restore it after the stub runs.
    # `remove_method` would strip the real implementation (which is defined
    # directly on Payouts' singleton class), leaking
    # `NameError: undefined method 'create_payments_for_balances_up_to_date_for_users'`
    # into sibling tests.
    orig_method = Payouts.singleton_class.instance_method(:create_payments_for_balances_up_to_date_for_users)
    stub = lambda { |_date, _proc, _users, **_opts| [[]] }
    Payouts.define_singleton_method(:create_payments_for_balances_up_to_date_for_users, stub)
    begin
      post :pay_user, params: { id: @user.external_id, payday: { payout_period_end_date: Date.today.iso8601, payout_processor: PayoutProcessorType::STRIPE } }
      assert_redirected_to admin_user_url(@user)
      assert_equal "Payment was not sent.", flash[:notice]
    ensure
      Payouts.singleton_class.send(:define_method, :create_payments_for_balances_up_to_date_for_users, orig_method)
    end
  end
end
