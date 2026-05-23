# frozen_string_literal: true

require "test_helper"

class ServiceChargePolicyTest < ActiveSupport::TestCase
  include PolicyAssertions

  ACTIONS = %i[create? confirm? resend_receipt? send_invoice? generate_service_charge_invoice?].freeze

  test "grants access to owner" do
    assert_policy_permits ServiceChargePolicy, ServiceCharge, :named_seller, *ACTIONS
  end
  test "denies access to accountant" do
    refute_policy_permits ServiceChargePolicy, ServiceCharge, :accountant_for_named_seller, *ACTIONS
  end
  test "denies access to admin" do
    refute_policy_permits ServiceChargePolicy, ServiceCharge, :admin_for_named_seller, *ACTIONS
  end
  test "denies access to marketing" do
    refute_policy_permits ServiceChargePolicy, ServiceCharge, :marketing_for_named_seller, *ACTIONS
  end
  test "denies access to support" do
    refute_policy_permits ServiceChargePolicy, ServiceCharge, :support_for_named_seller, *ACTIONS
  end
end
