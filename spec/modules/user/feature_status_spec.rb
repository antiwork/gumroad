# frozen_string_literal: true

require "spec_helper"

describe User::FeatureStatus do
  describe "#merchant_migration_enabled?" do
    it "returns true if either feature flag is enabled of else false" do
      creator = create(:user)
      create(:user_compliance_info, user: creator)

      expect(creator.merchant_migration_enabled?).to eq false

      creator.check_merchant_account_is_linked = true
      creator.save!
      expect(creator.reload.merchant_migration_enabled?).to eq true

      creator.check_merchant_account_is_linked = false
      creator.save!
      expect(creator.merchant_migration_enabled?).to eq false

      Feature.activate_user(:merchant_migration, creator)

      expect(creator.merchant_migration_enabled?).to eq true
    end

    it "returns false if user country is not supported by Stripe Connect" do
      creator = create(:user)
      create(:user_compliance_info, user: creator, country: "India")

      expect(creator.merchant_migration_enabled?).to eq false

      Feature.activate_user(:merchant_migration, creator)

      expect(creator.merchant_migration_enabled?).to eq false

      creator.check_merchant_account_is_linked = true
      creator.save!

      expect(creator.merchant_migration_enabled?).to eq true
    end
  end



  describe "#charge_paypal_payout_fee?" do
    let!(:seller) { create(:user) }
    before do
      create(:user_compliance_info, user: seller)
    end

    it "returns true if feature flag is set and user is not from Brazil or India and user should be charged fee" do
      expect(seller.charge_paypal_payout_fee?).to be true
    end

    it "returns false if paypal_payout_fee feature flag is disabled" do
      expect(seller.charge_paypal_payout_fee?).to be true

      Feature.deactivate(:paypal_payout_fee)

      expect(seller.charge_paypal_payout_fee?).to be false
    end

    it "returns false if paypal_payout_fee_waived flag is set of the user" do
      expect(seller.reload.charge_paypal_payout_fee?).to be true

      seller.update!(paypal_payout_fee_waived: true)

      expect(seller.reload.charge_paypal_payout_fee?).to be false
    end

    it "returns false if user is from Brazil or India" do
      expect(seller.charge_paypal_payout_fee?).to be true

      seller.alive_user_compliance_info.mark_deleted!
      create(:user_compliance_info, user: seller, country: "Brazil")
      expect(seller.reload.charge_paypal_payout_fee?).to be false

      seller.alive_user_compliance_info.mark_deleted!
      create(:user_compliance_info, user: seller, country: "India")
      expect(seller.reload.charge_paypal_payout_fee?).to be false

      seller.alive_user_compliance_info.mark_deleted!
      create(:user_compliance_info, user: seller, country: "Vietnam")
      expect(seller.reload.charge_paypal_payout_fee?).to be true
    end
  end

  describe "#has_stripe_account_connected?" do
    it "returns true if there is a connected Stripe account and merchant migration flag is enabled" do
      creator = create(:user)
      create(:user_compliance_info, user: creator)

      merchant_account = create(:merchant_account_stripe_connect, user: creator)
      creator.check_merchant_account_is_linked = true
      creator.save!

      expect(creator.reload.merchant_migration_enabled?).to eq true
      expect(creator.stripe_connect_account).to eq(merchant_account)
      expect(creator.has_stripe_account_connected?).to eq true
    end

    it "returns false if there is a connected Stripe account but merchant migration flag is not enabled" do
      creator = create(:user)
      create(:user_compliance_info, user: creator)

      merchant_account = create(:merchant_account_stripe_connect, user: creator)

      expect(creator.reload.merchant_migration_enabled?).to eq false
      expect(creator.stripe_connect_account).to eq(merchant_account)
      expect(creator.has_stripe_account_connected?).to eq false
    end

    it "returns false if there is no connected Stripe account" do
      creator = create(:user)
      create(:user_compliance_info, user: creator)

      Feature.activate_user(:merchant_migration, creator)

      expect(creator.reload.merchant_migration_enabled?).to eq true
      expect(creator.stripe_connect_account).to be nil
      expect(creator.has_stripe_account_connected?).to eq false
    end
  end

  describe "#has_paypal_account_connected?" do
    it "returns true if there is a connected PayPal account otherwise returns false" do
      creator = create(:user)
      create(:user_compliance_info, user: creator)
      expect(creator.has_paypal_account_connected?).to eq false

      merchant_account = create(:merchant_account_paypal, user: creator)
      expect(creator.paypal_connect_account).to eq(merchant_account)
      expect(creator.has_paypal_account_connected?).to eq true
    end
  end

  describe "#can_publish_products?" do
    let(:seller) { create(:compliant_user, payment_address: nil) }

    before do
      create(:user_compliance_info, user: seller)
    end

    it "returns false if no payout method is setup" do
      expect(seller.can_publish_products?).to be false
    end

    it "returns true if a bank account is setup", :vcr do
      create(:merchant_account_stripe, user: seller)

      expect(seller.can_publish_products?).to be true
    end

    it "returns true if a PayPal account is connected" do
      create(:merchant_account_paypal, user: seller)

      expect(seller.can_publish_products?).to be true
    end

    it "returns true if a Stripe account is connected" do
      create(:merchant_account_stripe_connect, user: seller)

      expect(seller.can_publish_products?).to be true
    end

    it "returns true if a PayPal payment address is present" do
      seller.update!(payment_address: "payme@example.com")

      expect(seller.can_publish_products?).to be true
    end
  end

  describe "#paypal_connect_allowed?" do
    let!(:seller) { create(:user) }

    before do
      seller.mark_compliant!(author_name: "Iffy")
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(100_00)
      create(:payment_completed, user: seller)
    end

    it "returns true if seller is compliant and has more than $100 in sales and a successful payout" do
      expect(seller.paypal_connect_allowed?).to eq true
    end

    it "returns false if seller is not compliant" do
      seller.update!(user_risk_state: "not_reviewed")
      expect(seller.reload.paypal_connect_allowed?).to eq false
    end

    it "returns false if seller does not have $100 in sales" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(99_00)
      expect(seller.reload.paypal_connect_allowed?).to eq false
    end

    it "returns false if seller does not have a successful payout" do
      seller.payments.last.update!(state: "failed")
      expect(seller.reload.paypal_connect_allowed?).to eq false
    end

    it "returns false if seller does not meet any eligibility requirement" do
      seller.update!(user_risk_state: "not_reviewed")
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(99_00)
      seller.payments.last.update!(state: "failed")

      expect(seller.reload.paypal_connect_allowed?).to eq false
    end
  end

  describe "#stripe_disconnect_allowed?" do
    it "returns true if there is no connected Stripe account" do
      creator = create(:user)
      create(:user_compliance_info, user: creator)

      expect(creator.merchant_migration_enabled?).to eq false
      expect(creator.has_stripe_account_connected?).to eq false
      expect(creator.stripe_disconnect_allowed?).to eq true
    end

    it "returns true if there is a connected Stripe account but no active subscriptions using it" do
      creator = create(:user)
      create(:user_compliance_info, user: creator)

      merchant_account = create(:merchant_account_stripe_connect, user: creator)
      creator.check_merchant_account_is_linked = true
      creator.save!

      expect_any_instance_of(User).to receive(:active_subscribers?).with(charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                                                         merchant_account:).and_return false

      expect(creator.reload.merchant_migration_enabled?).to eq true
      expect(creator.has_stripe_account_connected?).to eq true
      expect(creator.stripe_disconnect_allowed?).to eq true
    end

    it "returns false if there is a connected Stripe account and active subscriptions use it" do
      creator = create(:user)
      create(:user_compliance_info, user: creator)

      merchant_account = create(:merchant_account_stripe_connect, user: creator)
      creator.check_merchant_account_is_linked = true
      creator.save!

      expect_any_instance_of(User).to receive(:active_subscribers?).with(charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                                                         merchant_account:).and_return true

      expect(creator.reload.merchant_migration_enabled?).to eq true
      expect(creator.has_stripe_account_connected?).to eq true
      expect(creator.stripe_disconnect_allowed?).to eq false
    end
  end

  describe "#product_level_support_emails_enabled?" do
    let(:user) { create(:user) }

    it "returns true if product_level_support_emails feature flag is enabled for user" do
      Feature.activate_user(:product_level_support_emails, user)
      expect(user.product_level_support_emails_enabled?).to eq true

      Feature.deactivate_user(:product_level_support_emails, user)
      expect(user.product_level_support_emails_enabled?).to eq false

      Feature.activate(:product_level_support_emails)
      expect(user.product_level_support_emails_enabled?).to eq true

      Feature.deactivate(:product_level_support_emails)
      expect(user.product_level_support_emails_enabled?).to eq false
    end
  end

  describe "#waive_gumroad_fee_on_new_sales?" do
    it "returns true if waive_gumroad_fee_on_new_sales feature flag is set for seller" do
      seller = create(:user)

      Feature.activate_user(:waive_gumroad_fee_on_new_sales, seller)

      expect($redis.get(RedisKey.gumroad_day_date)).to be nil
      expect(seller.waive_gumroad_fee_on_new_sales?).to eq true
    end

    it "returns true if today is Gumroad day in seller's timezone" do
      seller = create(:user)

      $redis.set(RedisKey.gumroad_day_date, Time.now.in_time_zone(seller.timezone).to_date.to_s)

      expect(Feature.active?(:waive_gumroad_fee_on_new_sales, seller)).to be false
      expect(seller.waive_gumroad_fee_on_new_sales?).to be true
    end

    it "returns false if today is not Gumroad day and feature flag is not set for seller" do
      seller = create(:user)

      expect($redis.get(RedisKey.gumroad_day_date)).to be nil
      expect(Feature.active?(:waive_gumroad_fee_on_new_sales, seller)).to be false
      expect(seller.waive_gumroad_fee_on_new_sales?).to be false
    end

    it "returns false if today is Gumroad day in some other timezone but not in seller's timezone" do
      $redis.set(RedisKey.gumroad_day_date, "2024-4-4")

      seller_in_act = create(:user, timezone: "Melbourne")
      seller_in_utc = create(:user, timezone: "UTC")
      seller_in_pst = create(:user, timezone: "Pacific Time (US & Canada)")

      gumroad_day = Date.new(2024, 4, 4)
      gumroad_day_in_act = gumroad_day.in_time_zone("Melbourne")
      gumroad_day_in_utc = gumroad_day.in_time_zone("UTC")
      gumroad_day_in_pst = gumroad_day.in_time_zone("Pacific Time (US & Canada)")

      travel_to(gumroad_day_in_act.beginning_of_day) do
        expect(seller_in_act.waive_gumroad_fee_on_new_sales?).to be true
        expect(seller_in_utc.waive_gumroad_fee_on_new_sales?).to be false
        expect(seller_in_pst.waive_gumroad_fee_on_new_sales?).to be false
      end

      travel_to(gumroad_day_in_utc.beginning_of_day) do
        expect(seller_in_act.waive_gumroad_fee_on_new_sales?).to be true
        expect(seller_in_utc.waive_gumroad_fee_on_new_sales?).to be true
        expect(seller_in_pst.waive_gumroad_fee_on_new_sales?).to be false
      end

      travel_to(gumroad_day_in_pst.beginning_of_day) do
        expect(seller_in_act.waive_gumroad_fee_on_new_sales?).to be true
        expect(seller_in_utc.waive_gumroad_fee_on_new_sales?).to be true
        expect(seller_in_pst.waive_gumroad_fee_on_new_sales?).to be true
      end

      travel_to(gumroad_day_in_act.end_of_day) do
        expect(seller_in_act.waive_gumroad_fee_on_new_sales?).to be true
        expect(seller_in_utc.waive_gumroad_fee_on_new_sales?).to be true
        expect(seller_in_pst.waive_gumroad_fee_on_new_sales?).to be true
      end

      travel_to(gumroad_day_in_utc.end_of_day) do
        expect(seller_in_act.waive_gumroad_fee_on_new_sales?).to be false
        expect(seller_in_utc.waive_gumroad_fee_on_new_sales?).to be true
        expect(seller_in_pst.waive_gumroad_fee_on_new_sales?).to be true
      end

      travel_to(gumroad_day_in_pst.end_of_day) do
        expect(seller_in_act.waive_gumroad_fee_on_new_sales?).to be false
        expect(seller_in_utc.waive_gumroad_fee_on_new_sales?).to be false
        expect(seller_in_pst.waive_gumroad_fee_on_new_sales?).to be true
      end
    end

    it "uses seller's gumroad_day_timezone when present to check if it is Gumroad Day" do
      $redis.set(RedisKey.gumroad_day_date, "2024-4-4")
      gumroad_day = Date.new(2024, 4, 4)
      gumroad_day_in_act = gumroad_day.in_time_zone("Melbourne")
      gumroad_day_in_pst = gumroad_day.in_time_zone("Pacific Time (US & Canada)")

      seller_in_act = create(:user, timezone: "Melbourne")

      travel_to(gumroad_day_in_act.beginning_of_day) do
        expect(seller_in_act.waive_gumroad_fee_on_new_sales?).to be true
      end

      seller_in_act.update!(timezone: "Pacific Time (US & Canada)")

      travel_to(gumroad_day_in_pst.end_of_day) do
        expect(seller_in_act.waive_gumroad_fee_on_new_sales?).to be true
      end

      seller_in_act.update!(gumroad_day_timezone: "Melbourne")
      expect(seller_in_act.reload.gumroad_day_timezone).to eq("Melbourne")

      travel_to(gumroad_day_in_act.end_of_day) do
        expect(seller_in_act.waive_gumroad_fee_on_new_sales?).to be true
      end

      travel_to(gumroad_day_in_act.end_of_day + 1) do
        expect(seller_in_act.waive_gumroad_fee_on_new_sales?).to be false
      end

      travel_to(gumroad_day_in_pst.end_of_day) do
        expect(seller_in_act.waive_gumroad_fee_on_new_sales?).to be false
      end
    end
  end
end
