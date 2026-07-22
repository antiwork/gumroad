# frozen_string_literal: true

require "test_helper"

# Ported from spec/modules/user/feature_status_spec.rb (#5801).
# Exercises the User::FeatureStatus module (payout/merchant capability
# predicates). The one Stripe-backed example ("a bank account is setup") builds
# a real Stripe Connect account and replays it from the shared VCR cassette.
class User::FeatureStatusTest < ActiveSupport::TestCase
  # --- #merchant_migration_enabled? -------------------------------------------

  test "#merchant_migration_enabled? is true when the account is linked or the feature is on for a supported country" do
    creator = create_user
    create_user_compliance_info(user: creator)

    assert_equal false, creator.merchant_migration_enabled?

    creator.check_merchant_account_is_linked = true
    creator.save!
    assert_equal true, creator.reload.merchant_migration_enabled?

    creator.check_merchant_account_is_linked = false
    creator.save!
    assert_equal false, creator.merchant_migration_enabled?

    Feature.activate_user(:merchant_migration, creator)
    assert_equal true, creator.merchant_migration_enabled?
  end

  test "#merchant_migration_enabled? is false when the user country is not supported by Stripe Connect" do
    creator = create_user
    create_user_compliance_info(user: creator, country: "India")

    assert_equal false, creator.merchant_migration_enabled?

    Feature.activate_user(:merchant_migration, creator)
    assert_equal false, creator.merchant_migration_enabled?

    creator.check_merchant_account_is_linked = true
    creator.save!
    assert_equal true, creator.merchant_migration_enabled?
  end

  # --- #charge_paypal_payout_fee? ---------------------------------------------

  test "#charge_paypal_payout_fee? is true when the feature is on, the user is not from Brazil or India, and the fee applies" do
    seller = seller_with_us_compliance
    assert_equal true, seller.charge_paypal_payout_fee?
  end

  test "#charge_paypal_payout_fee? is false when the paypal_payout_fee feature is disabled" do
    seller = seller_with_us_compliance
    assert_equal true, seller.charge_paypal_payout_fee?

    Feature.deactivate(:paypal_payout_fee)
    assert_equal false, seller.charge_paypal_payout_fee?
  end

  test "#charge_paypal_payout_fee? is false when the user has the payout fee waived" do
    seller = seller_with_us_compliance
    assert_equal true, seller.reload.charge_paypal_payout_fee?

    seller.update!(paypal_payout_fee_waived: true)
    assert_equal false, seller.reload.charge_paypal_payout_fee?
  end

  test "#charge_paypal_payout_fee? is false when the user is from Brazil or India" do
    seller = seller_with_us_compliance
    assert_equal true, seller.charge_paypal_payout_fee?

    seller.alive_user_compliance_info.mark_deleted!
    create_user_compliance_info(user: seller, country: "Brazil")
    assert_equal false, seller.reload.charge_paypal_payout_fee?

    seller.alive_user_compliance_info.mark_deleted!
    create_user_compliance_info(user: seller, country: "India")
    assert_equal false, seller.reload.charge_paypal_payout_fee?

    seller.alive_user_compliance_info.mark_deleted!
    create_user_compliance_info(user: seller, country: "Vietnam")
    assert_equal true, seller.reload.charge_paypal_payout_fee?
  end

  # --- #has_stripe_account_connected? -----------------------------------------

  test "#has_stripe_account_connected? is true when a Stripe account is connected and merchant migration is enabled" do
    creator = create_user
    create_user_compliance_info(user: creator)

    merchant_account = create_merchant_account_stripe_connect(user: creator)
    creator.check_merchant_account_is_linked = true
    creator.save!

    assert_equal true, creator.reload.merchant_migration_enabled?
    assert_equal merchant_account, creator.stripe_connect_account
    assert_equal true, creator.has_stripe_account_connected?
  end

  test "#has_stripe_account_connected? is false when a Stripe account is connected but merchant migration is not enabled" do
    creator = create_user
    create_user_compliance_info(user: creator)

    merchant_account = create_merchant_account_stripe_connect(user: creator)

    assert_equal false, creator.reload.merchant_migration_enabled?
    assert_equal merchant_account, creator.stripe_connect_account
    assert_equal false, creator.has_stripe_account_connected?
  end

  test "#has_stripe_account_connected? is false when there is no connected Stripe account" do
    creator = create_user
    create_user_compliance_info(user: creator)

    Feature.activate_user(:merchant_migration, creator)

    assert_equal true, creator.reload.merchant_migration_enabled?
    assert_nil creator.stripe_connect_account
    assert_equal false, creator.has_stripe_account_connected?
  end

  # --- #has_paypal_account_connected? -----------------------------------------

  test "#has_paypal_account_connected? reflects whether a PayPal account is connected" do
    creator = create_user
    create_user_compliance_info(user: creator)
    assert_equal false, creator.has_paypal_account_connected?

    merchant_account = create_merchant_account_paypal(user: creator)
    assert_equal merchant_account, creator.paypal_connect_account
    assert_equal true, creator.has_paypal_account_connected?
  end

  # --- #can_publish_products? -------------------------------------------------

  test "#can_publish_products? is false when no payout method is set up" do
    seller = can_publish_seller
    assert_equal false, seller.can_publish_products?
  end

  test "#can_publish_products? is true when a bank account is set up" do
    seller = can_publish_seller
    VCR.use_cassette("User_FeatureStatus/_can_publish_products_/returns_true_if_a_bank_account_is_setup") do
      create_merchant_account_stripe(user: seller)
    end

    assert_equal true, seller.can_publish_products?
  end

  test "#can_publish_products? is true when a PayPal account is connected" do
    seller = can_publish_seller
    create_merchant_account_paypal(user: seller)

    assert_equal true, seller.can_publish_products?
  end

  test "#can_publish_products? is true when a Stripe account is connected" do
    seller = can_publish_seller
    create_merchant_account_stripe_connect(user: seller)

    assert_equal true, seller.can_publish_products?
  end

  test "#can_publish_products? is true when a PayPal payment address is present" do
    seller = can_publish_seller
    seller.update!(payment_address: "payme@example.com")

    assert_equal true, seller.can_publish_products?
  end

  test "#can_publish_products? is true for an admin team member without any payment methods" do
    seller = can_publish_seller
    seller.update!(is_team_member: true)

    assert_equal true, seller.can_publish_products?
  end

  # --- #can_setup_bank_payouts? -----------------------------------------------

  test "#can_setup_bank_payouts? is true for Stripe-supported countries (except India without an active bank account)" do
    (User::Compliance.const_get(:SUPPORTED_COUNTRIES) - [Compliance::Countries::IND]).each do |country|
      seller = create_user
      create_user_compliance_info(user: seller, country: country.common_name)
      assert seller.can_setup_bank_payouts?, "expected #{country.common_name} to support bank payouts"
    end
  end

  test "#can_setup_bank_payouts? is true when the user has an active bank account" do
    seller = create_user
    create_ach_account_stripe_succeed(user: seller)
    assert_equal true, seller.can_setup_bank_payouts?
  end

  test "#can_setup_bank_payouts? is false when the country is unsupported and there is no active bank account" do
    seller = create_user
    create_user_compliance_info(user: seller, country: "Brazil")
    assert_equal false, seller.can_setup_bank_payouts?
  end

  test "#can_setup_bank_payouts? is true for UAE users" do
    seller = create_user
    create_user_compliance_info(user: seller, country: "United Arab Emirates")
    assert_equal true, seller.can_setup_bank_payouts?
  end

  test "#can_setup_bank_payouts? is false for new India users without an active bank account" do
    seller = create_user
    create_user_compliance_info(user: seller, country: "India")
    assert_equal false, seller.can_setup_bank_payouts?
  end

  test "#can_setup_bank_payouts? is true for India users with an active bank account" do
    seller = create_user
    create_user_compliance_info(user: seller, country: "India")
    create_indian_bank_account(user: seller)
    assert_equal true, seller.can_setup_bank_payouts?
  end

  # --- #can_setup_paypal_payouts? ---------------------------------------------

  test "#can_setup_paypal_payouts? is true when the user already has a payment address" do
    seller = create_user(payment_address: "paypal@example.com")
    create_user_compliance_info(user: seller, country: "United States")
    assert_equal true, seller.can_setup_paypal_payouts?
  end

  test "#can_setup_paypal_payouts? is true when the country is not in the Stripe supported list" do
    seller = create_user(payment_address: nil)
    create_user_compliance_info(user: seller, country: "Brazil")
    assert_equal true, seller.can_setup_paypal_payouts?
  end

  test "#can_setup_paypal_payouts? is true for UAE users" do
    seller = create_user(payment_address: nil)
    create_user_compliance_info(user: seller, country: "United Arab Emirates")
    assert_equal true, seller.can_setup_paypal_payouts?
  end

  test "#can_setup_paypal_payouts? is true for Egypt users" do
    seller = create_user(payment_address: nil)
    create_user_compliance_info(user: seller, country: "Egypt")
    assert_equal true, seller.can_setup_paypal_payouts?
  end

  test "#can_setup_paypal_payouts? is true for Kazakhstan users" do
    seller = create_user(payment_address: nil)
    create_user_compliance_info(user: seller, country: "Kazakhstan")
    assert_equal true, seller.can_setup_paypal_payouts?
  end

  test "#can_setup_paypal_payouts? is true for India users" do
    seller = create_user(payment_address: nil)
    create_user_compliance_info(user: seller, country: "India")
    assert_equal true, seller.can_setup_paypal_payouts?
  end

  test "#can_setup_paypal_payouts? is false for Stripe-supported countries except UAE, Kazakhstan, Egypt, and India" do
    exempt = [Compliance::Countries::ARE, Compliance::Countries::KAZ, Compliance::Countries::EGY, Compliance::Countries::IND]
    (User::Compliance.const_get(:SUPPORTED_COUNTRIES) - exempt).each do |country|
      seller = create_user(payment_address: nil)
      create_user_compliance_info(user: seller, country: country.common_name)
      assert_not seller.can_setup_paypal_payouts?, "expected #{country.common_name} not to allow PayPal payout setup"
    end
  end

  # --- #paypal_connect_allowed? -----------------------------------------------

  # Eligibility relaxed in #6127 (see issue #6118): the only requirement is that
  # the seller has set up how they receive payouts. The earlier minimum-sales,
  # completed-payout, and compliant-status gates (added by #755 as a new-user
  # fraud control) are all removed.
  test "#paypal_connect_allowed? is true when the seller has payout information set up" do
    seller = paypal_connect_seller
    assert_equal true, seller.paypal_connect_allowed?
  end

  test "#paypal_connect_allowed? does not require compliant status, sales, or payouts" do
    seller = paypal_connect_seller
    seller.update!(user_risk_state: "not_reviewed")
    User.any_instance.stubs(:sales_cents_total).returns(0)
    assert_equal true, seller.reload.paypal_connect_allowed?
  end

  test "#paypal_connect_allowed? is false when the seller has no payout information" do
    seller = paypal_connect_seller
    seller.update!(payment_address: "")
    assert_equal false, seller.reload.paypal_connect_allowed?
  end

  # --- #stripe_disconnect_allowed? --------------------------------------------

  test "#stripe_disconnect_allowed? is true when there is no connected Stripe account" do
    creator = create_user
    create_user_compliance_info(user: creator)

    assert_equal false, creator.merchant_migration_enabled?
    assert_equal false, creator.has_stripe_account_connected?
    assert_equal true, creator.stripe_disconnect_allowed?
  end

  test "#stripe_disconnect_allowed? is true when a Stripe account is connected but no active subscriptions use it" do
    creator = create_user
    create_user_compliance_info(user: creator)

    merchant_account = create_merchant_account_stripe_connect(user: creator)
    creator.check_merchant_account_is_linked = true
    creator.save!

    User.any_instance.expects(:active_subscribers?)
        .with(charge_processor_id: StripeChargeProcessor.charge_processor_id, merchant_account:)
        .returns(false)

    assert_equal true, creator.reload.merchant_migration_enabled?
    assert_equal true, creator.has_stripe_account_connected?
    assert_equal true, creator.stripe_disconnect_allowed?
  end

  test "#stripe_disconnect_allowed? is false when a Stripe account is connected and active subscriptions use it" do
    creator = create_user
    create_user_compliance_info(user: creator)

    merchant_account = create_merchant_account_stripe_connect(user: creator)
    creator.check_merchant_account_is_linked = true
    creator.save!

    User.any_instance.expects(:active_subscribers?)
        .with(charge_processor_id: StripeChargeProcessor.charge_processor_id, merchant_account:)
        .returns(true)

    assert_equal true, creator.reload.merchant_migration_enabled?
    assert_equal true, creator.has_stripe_account_connected?
    assert_equal false, creator.stripe_disconnect_allowed?
  end

  # --- #waive_gumroad_fee_on_new_sales? ---------------------------------------

  test "#waive_gumroad_fee_on_new_sales? is true when the feature is set for the seller" do
    seller = create_user

    Feature.activate_user(:waive_gumroad_fee_on_new_sales, seller)

    assert_nil $redis.get(RedisKey.gumroad_day_date)
    assert_equal true, seller.waive_gumroad_fee_on_new_sales?
  end

  test "#waive_gumroad_fee_on_new_sales? is true when today is Gumroad day in the seller's timezone" do
    seller = create_user

    $redis.set(RedisKey.gumroad_day_date, Time.now.in_time_zone(seller.timezone).to_date.to_s)

    assert_equal false, Feature.active?(:waive_gumroad_fee_on_new_sales, seller)
    assert_equal true, seller.waive_gumroad_fee_on_new_sales?
  end

  test "#waive_gumroad_fee_on_new_sales? is false when it is not Gumroad day and the feature is not set" do
    seller = create_user

    assert_nil $redis.get(RedisKey.gumroad_day_date)
    assert_equal false, Feature.active?(:waive_gumroad_fee_on_new_sales, seller)
    assert_equal false, seller.waive_gumroad_fee_on_new_sales?
  end

  test "#waive_gumroad_fee_on_new_sales? tracks Gumroad day per seller timezone" do
    $redis.set(RedisKey.gumroad_day_date, "2024-4-4")

    seller_in_act = create_user(timezone: "Melbourne")
    seller_in_utc = create_user(timezone: "UTC")
    seller_in_pst = create_user(timezone: "Pacific Time (US & Canada)")

    gumroad_day = Date.new(2024, 4, 4)
    gumroad_day_in_act = gumroad_day.in_time_zone("Melbourne")
    gumroad_day_in_utc = gumroad_day.in_time_zone("UTC")
    gumroad_day_in_pst = gumroad_day.in_time_zone("Pacific Time (US & Canada)")

    travel_to(gumroad_day_in_act.beginning_of_day) do
      assert_equal true, seller_in_act.waive_gumroad_fee_on_new_sales?
      assert_equal false, seller_in_utc.waive_gumroad_fee_on_new_sales?
      assert_equal false, seller_in_pst.waive_gumroad_fee_on_new_sales?
    end

    travel_to(gumroad_day_in_utc.beginning_of_day) do
      assert_equal true, seller_in_act.waive_gumroad_fee_on_new_sales?
      assert_equal true, seller_in_utc.waive_gumroad_fee_on_new_sales?
      assert_equal false, seller_in_pst.waive_gumroad_fee_on_new_sales?
    end

    travel_to(gumroad_day_in_pst.beginning_of_day) do
      assert_equal true, seller_in_act.waive_gumroad_fee_on_new_sales?
      assert_equal true, seller_in_utc.waive_gumroad_fee_on_new_sales?
      assert_equal true, seller_in_pst.waive_gumroad_fee_on_new_sales?
    end

    travel_to(gumroad_day_in_act.end_of_day) do
      assert_equal true, seller_in_act.waive_gumroad_fee_on_new_sales?
      assert_equal true, seller_in_utc.waive_gumroad_fee_on_new_sales?
      assert_equal true, seller_in_pst.waive_gumroad_fee_on_new_sales?
    end

    travel_to(gumroad_day_in_utc.end_of_day) do
      assert_equal false, seller_in_act.waive_gumroad_fee_on_new_sales?
      assert_equal true, seller_in_utc.waive_gumroad_fee_on_new_sales?
      assert_equal true, seller_in_pst.waive_gumroad_fee_on_new_sales?
    end

    travel_to(gumroad_day_in_pst.end_of_day) do
      assert_equal false, seller_in_act.waive_gumroad_fee_on_new_sales?
      assert_equal false, seller_in_utc.waive_gumroad_fee_on_new_sales?
      assert_equal true, seller_in_pst.waive_gumroad_fee_on_new_sales?
    end
  end

  test "#waive_gumroad_fee_on_new_sales? uses the seller's gumroad_day_timezone when present" do
    $redis.set(RedisKey.gumroad_day_date, "2024-4-4")
    gumroad_day = Date.new(2024, 4, 4)
    gumroad_day_in_act = gumroad_day.in_time_zone("Melbourne")
    gumroad_day_in_pst = gumroad_day.in_time_zone("Pacific Time (US & Canada)")

    seller_in_act = create_user(timezone: "Melbourne")

    travel_to(gumroad_day_in_act.beginning_of_day) do
      assert_equal true, seller_in_act.waive_gumroad_fee_on_new_sales?
    end

    seller_in_act.update!(timezone: "Pacific Time (US & Canada)")

    travel_to(gumroad_day_in_pst.end_of_day) do
      assert_equal true, seller_in_act.waive_gumroad_fee_on_new_sales?
    end

    seller_in_act.update!(gumroad_day_timezone: "Melbourne")
    assert_equal "Melbourne", seller_in_act.reload.gumroad_day_timezone

    travel_to(gumroad_day_in_act.end_of_day) do
      assert_equal true, seller_in_act.waive_gumroad_fee_on_new_sales?
    end

    travel_to(gumroad_day_in_act.end_of_day + 1) do
      assert_equal false, seller_in_act.waive_gumroad_fee_on_new_sales?
    end

    travel_to(gumroad_day_in_pst.end_of_day) do
      assert_equal false, seller_in_act.waive_gumroad_fee_on_new_sales?
    end
  end

  private
    # A US-compliant seller, matching the `#charge_paypal_payout_fee?`
    # describe's `let!(:seller)` + `create(:user_compliance_info)` before hook.
    def seller_with_us_compliance
      seller = create_user
      create_user_compliance_info(user: seller)
      seller
    end

    # The `#can_publish_products?` describe's `let(:seller)`: a compliant seller
    # with no payment address and a compliance record.
    def can_publish_seller
      seller = create_user(user_risk_state: "compliant", payment_address: nil)
      create_user_compliance_info(user: seller)
      seller
    end

    # The `#paypal_connect_allowed?` describe's `let!(:seller)` + before hook: a
    # seller with payout information set up (a PayPal payout email).
    def paypal_connect_seller
      create_user(payment_address: "seller-payouts-#{unique_suffix}@example.com")
    end
end
