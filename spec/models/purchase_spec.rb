# frozen_string_literal: true

require "spec_helper"

describe Purchase, :vcr do
  include CurrencyHelper
  include ProductsHelper

  def verify_balance(user, expected_balance)
    expect(user.unpaid_balance_cents).to eq expected_balance
  end

  let(:ip_address) { "24.7.90.214" }
  let(:initial_balance) { 200 }
  let(:user) { create(:user, unpaid_balance_cents: initial_balance) }
  let(:link) { create(:product, user:) }
  let(:chargeable) { create :chargeable }

  before do
    allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
  end

  describe "scopes" do
    describe "in_progress" do
      before do
        @in_progress_purchase = create(:purchase, purchase_state: "in_progress")
        @successful_purchase = create(:purchase, purchase_state: "successful")
      end

      it "returns in_progress purchases" do
        expect(Purchase.in_progress).to include @in_progress_purchase
      end

      it "does not return failed purchases" do
        expect(Purchase.in_progress).to_not include @successful_purchase
      end
    end

    describe "successful" do
      before do
        @successful_purchase = create(:purchase, purchase_state: "successful")
        @failed_purchase = create(:purchase, purchase_state: "failed")
      end

      it "returns successful purchases" do
        expect(Purchase.successful).to include @successful_purchase
      end

      it "does not return failed purchases" do
        expect(Purchase.successful).to_not include @failed_purchase
      end
    end

    describe ".not_successful" do
      before do
        @successful_purchase = create(:purchase, purchase_state: "successful")
        @failed_purchase = create(:purchase, purchase_state: "failed")
      end

      it "returns only unsuccessful purchases" do
        expect(described_class.not_successful).to include @failed_purchase
        expect(described_class.not_successful).to_not include @successful_purchase
      end
    end

    describe "failed" do
      before do
        @successful_purchase = create(:purchase, purchase_state: "successful")
        @failed_purchase = create(:purchase, purchase_state: "failed")
      end

      it "does not returns successful purchases" do
        expect(Purchase.failed).to_not include @successful_purchase
      end

      it "does return failed purchases" do
        expect(Purchase.failed).to include @failed_purchase
      end
    end

    describe "stripe_failed" do
      before do
        @failed_purchase_no_stripe_fingerprint = create(:purchase, stripe_fingerprint: nil, purchase_state: "failed")
        @failed_purchase_with_stripe_fingerprint = create(:purchase, stripe_fingerprint: "asdfas235afasa", purchase_state: "failed")
        @successful_purchase_with_stripe_fingerprint = create(:purchase, stripe_fingerprint: "asdfas235afasa", purchase_state: "successful")
      end

      it "returns failed purchases with non-blank stripe fingerprint" do
        expect(Purchase.stripe_failed).to include @failed_purchase_with_stripe_fingerprint
      end

      it "does not return successful purchases" do
        expect(Purchase.stripe_failed).to_not include @successful_purchase_with_stripe_fingerprint
      end

      it "does not return failed purchases with blank stripe fingerprint" do
        expect(Purchase.stripe_failed).to_not include @failed_purchase_no_stripe_fingerprint
      end
    end

    describe "non_free" do
      before do
        @non_zero_fee = create(:purchase)
        @zero_fee = create(:free_purchase)
      end

      it "returns purchases with fee > 0" do
        expect(Purchase.non_free).to include @non_zero_fee
      end

      it "does not return purchases with 0 fee" do
        expect(Purchase.non_free).to_not include @zero_fee
      end
    end

    describe "paid" do
      before do
        @non_refunded_purchase = create(:purchase, price_cents: 300, stripe_refunded: nil)
        @free_purchase = create(:purchase, link: create(:product, price_range: "0+"), price_cents: 0, stripe_transaction_id: nil, stripe_fingerprint: nil)
        @refunded_purchase = create(:purchase, price_cents: 300, stripe_refunded: true)
      end

      it "returns non-refunded non-free purchases" do
        expect(Purchase.paid).to include @non_refunded_purchase
      end

      it "does not return refunded purchases" do
        expect(Purchase.paid).to_not include @refunded_purchase
      end

      it "does not return free purchases" do
        expect(Purchase.paid).to_not include @free_purchase
      end

      it "has charge processor id set" do
        expect(@non_refunded_purchase.charge_processor_id).to be_present
        expect(@free_purchase.charge_processor_id).to be(nil)
        expect(@refunded_purchase.charge_processor_id).to be_present
      end
    end

    describe "not_fully_refunded" do
      before do
        @refunded_purchase = create(:purchase, stripe_refunded: true)
        @non_refunded_purchase = create(:purchase, stripe_refunded: nil)
      end

      it "returns non-refunded purchases" do
        expect(Purchase.not_fully_refunded).to include @non_refunded_purchase
      end

      it "does not return refunded purchases" do
        expect(Purchase.not_fully_refunded).to_not include @refunded_purchase
      end
    end

    describe "not_chargedback" do
      before do
        @chargebacked_purchase = create(:purchase, chargeback_date: Date.yesterday)
        @reversed_chargebacked_purchase = create(:purchase, chargeback_date: Date.yesterday, chargeback_reversed: true)
        @non_chargebacked_purchase = create(:purchase)
      end

      it "does not return chargebacked purchase" do
        expect(Purchase.not_chargedback).to_not include @chargebacked_purchase
        expect(Purchase.not_chargedback).to_not include @reversed_chargebacked_purchase
      end

      it "returns non-chargebacked purchase" do
        expect(Purchase.not_chargedback).to include @non_chargebacked_purchase
        expect(Purchase.not_chargedback).to_not include @reversed_chargebacked_purchase
      end
    end

    describe "not_chargedback_or_chargedback_reversed" do
      before do
        @chargebacked_purchase = create(:purchase, chargeback_date: Date.yesterday)
        @reversed_chargebacked_purchase = create(:purchase, chargeback_date: Date.yesterday, chargeback_reversed: true)
        @non_chargebacked_purchase = create(:purchase)
      end

      it "does not return chargebacked purchase" do
        expect(Purchase.not_chargedback_or_chargedback_reversed).to_not include @chargebacked_purchase
      end

      it "returns non-chargebacked purchase" do
        expect(Purchase.not_chargedback_or_chargedback_reversed).to include @non_chargebacked_purchase
      end

      it "returns chargebacked reversed purchase" do
        expect(Purchase.not_chargedback_or_chargedback_reversed).to include @reversed_chargebacked_purchase
      end
    end

    describe "additional contribution and max purchase quantity" do
      before do
        @product = create(:product, max_purchase_count: 1)
        @purchase = create(:purchase, link: @product, is_additional_contribution: true)
      end

      it "does not count the additional contribution towards the max quantity" do
        expect(@product.remaining_for_sale_count).to eq 1
      end
    end

    describe "not_additional_contribution" do
      before do
        @additional_contribution = create(:purchase, is_additional_contribution: true)
        @not_additional_contribution = create(:purchase)
      end

      it "returns puchases that are not additional contributions" do
        expect(Purchase.not_additional_contribution).to include @not_additional_contribution
      end

      it "does not return purchases that are additional contribution" do
        expect(Purchase.not_additional_contribution).to_not include @additional_contribution
      end
    end

    describe "not_recurring_charge" do
      before do
        @normal_purchase = create(:purchase)
        subscription = create(:subscription)
        @original_subscription_purchase = create(:purchase, subscription:, is_original_subscription_purchase: true)
        @recurring_purchase = create(:purchase, subscription:, is_original_subscription_purchase: false)
      end

      it "does not return purchases that are subscriptions and not original_subscription_purchase" do
        expect(Purchase.not_recurring_charge).to_not include @recurring_purchase
      end

      it "returns purchases that are original_subscription_purchase" do
        expect(Purchase.not_recurring_charge).to include @original_subscription_purchase
      end

      it "returns normal purchases" do
        expect(Purchase.not_recurring_charge).to include @normal_purchase
      end
    end

    describe "recurring_charge" do
      before do
        @normal_purchase = create(:purchase)
        subscription = create(:subscription)
        @original_subscription_purchase = create(:purchase, subscription:, is_original_subscription_purchase: true)
        @recurring_purchase = create(:purchase, subscription:, is_original_subscription_purchase: false)
      end

      it "does not return purchases that are original_subscription_purchase" do
        expect(Purchase.recurring_charge).to_not include @original_subscription_purchase
      end

      it "returns purchases that are original_subscription_purchase" do
        expect(Purchase.recurring_charge).to include @recurring_purchase
      end

      it "does not return normal purchases" do
        expect(Purchase.recurring_charge).to_not include @normal_purchase
      end
    end

    describe ".paypal_orders" do
      before do
        @paypal_order_purchase = create(:purchase, paypal_order_id: "SamplePaypalOrderID")
        @non_paypal_order_purchase = create(:purchase)
      end

      it "returns only paypal order purchases" do
        expect(described_class.paypal_orders).to include @paypal_order_purchase
        expect(described_class.paypal_orders).to_not include @non_paypal_order_purchase
      end
    end

    describe ".unsuccessful_paypal_orders" do
      before do
        @unsuccessful_paypal_order_purchase = create(:purchase, paypal_order_id: "SamplePaypalOrderID1",
                                                                purchase_state: "in_progress",
                                                                created_at: 1.hour.ago)

        @obsolete_unsuccessful_paypal_order_purchase = create(:purchase, paypal_order_id: "SamplePaypalOrderID1",
                                                                         purchase_state: "in_progress",
                                                                         created_at: 4.hours.ago)

        @recent_unsuccessful_paypal_order_purchase = create(:purchase, paypal_order_id: "SamplePaypalOrderID2",
                                                                       purchase_state: "in_progress",
                                                                       created_at: 1.minute.ago)

        @successful_paypal_order_purchase = create(:purchase, paypal_order_id: "SamplePaypalOrderID3",
                                                              purchase_state: "successful",
                                                              created_at: 1.hour.ago)

        @successful_non_paypal_order_purchase = create(:purchase, purchase_state: "successful",
                                                                  created_at: 1.hour.ago)

        @unsuccessful_non_paypal_order_purchase = create(:purchase, purchase_state: "in_progress",
                                                                    created_at: 1.hour.ago)

        @unsuccessful_paypal_order_purchases = described_class.unsuccessful_paypal_orders(2.5.hours.ago, 0.5.hours.ago)
      end

      it "returns only unsuccessful paypal order purchases created in specified time" do
        expect(@unsuccessful_paypal_order_purchases).to include @unsuccessful_paypal_order_purchase
        expect(@unsuccessful_paypal_order_purchases).to_not include @obsolete_unsuccessful_paypal_order_purchase
        expect(@unsuccessful_paypal_order_purchases).to_not include @recent_unsuccessful_paypal_order_purchase
        expect(@unsuccessful_paypal_order_purchases).to_not include @successful_paypal_order_purchase
        expect(@unsuccessful_paypal_order_purchases).to_not include @successful_non_paypal_order_purchase
        expect(@unsuccessful_paypal_order_purchases).to_not include @unsuccessful_non_paypal_order_purchase
      end
    end

    describe ".with_credit_card_id" do
      it "returns the records with a credit_card_id value present" do
        purchase1 = create(:purchase, credit_card_id: create(:credit_card).id)
        purchase2 = create(:purchase)
        purchase3 = create(:purchase, credit_card_id: create(:credit_card).id)

        result = described_class.with_credit_card_id
        expect(result).to include purchase1
        expect(result).to_not include purchase2
        expect(result).to include purchase3
      end
    end

    describe ".not_rental_expired" do
      it "returns purchases where rental_expired field is nil or false" do
        purchase1 = create(:purchase, rental_expired: true)
        purchase2 = create(:purchase, rental_expired: false)
        purchase3 = create(:purchase, rental_expired: nil)
        expect(Purchase.not_rental_expired).to include(purchase2)
        expect(Purchase.not_rental_expired).to include(purchase3)
        expect(Purchase.not_rental_expired).not_to include(purchase1)
      end
    end

    describe ".for_library" do
      it "excludes archived original subscription purchases" do
        purchase = create(:purchase, is_archived_original_subscription_purchase: true)

        expect(Purchase.for_library).not_to include(purchase)
      end

      it "includes updated original subscription purchases with not_charged state" do
        purchase = create(:purchase, purchase_state: "not_charged")

        expect(Purchase.for_library).to include(purchase)
      end

      it "excludes purchase with access revoked" do
        purchase = create(:purchase, is_access_revoked: true)

        expect(Purchase.for_library).not_to include(purchase)
      end
    end

    describe ".for_mobile_listing" do
      it "returns successful purchases" do
        digital = create(:purchase, purchase_state: "successful")
        subscription = create(:purchase, is_original_subscription_purchase: true, purchase_state: "successful")
        updated_subscription = create(:purchase, is_original_subscription_purchase: true, purchase_state: "not_charged")
        archived = create(:purchase, purchase_state: "successful", is_archived: true)
        gift = create(:purchase, purchase_state: "gift_receiver_purchase_successful")

        expect(Purchase.for_mobile_listing).to match_array [digital, subscription, updated_subscription, gift, archived]
      end

      it "excludes failed, refunded or chargedback, gift sender, recurring charge, buyer deleted, and expired rental purchases" do
        create(:purchase, purchase_state: "failed")
        create(:purchase, purchase_state: "successful", is_additional_contribution: true)
        create(:purchase, purchase_state: "successful", is_gift_sender_purchase: true)
        create(:purchase, purchase_state: "successful", stripe_refunded: true)
        create(:purchase, purchase_state: "successful", chargeback_date: 1.day.ago)
        create(:purchase, purchase_state: "successful", rental_expired: true)
        create(:purchase, purchase_state: "successful", is_deleted_by_buyer: true)
        original_purchase = create(:membership_purchase)
        create(:membership_purchase, purchase_state: "successful", is_original_subscription_purchase: false, subscription: original_purchase.subscription)
        create(:membership_purchase, purchase_state: "successful", is_original_subscription_purchase: true, is_archived_original_subscription_purchase: true)

        expect(Purchase.where.not(id: original_purchase.id).for_mobile_listing).to be_empty
      end
    end

    describe ".for_sales_api" do
      it "includes successful purchases" do
        purchase = create(:purchase, purchase_state: "successful")
        expect(Purchase.for_sales_api).to match_array [purchase]
      end

      it "includes free trial not_charged purchases" do
        purchase = create(:free_trial_membership_purchase)
        expect(Purchase.for_sales_api).to match_array [purchase]
      end

      it "does not include other purchases" do
        %w(
          failed
          gift_receiver_purchase_successful
          preorder_authorization_successful
          test_successful
        ).each do |purchase_state|
          create(:purchase, purchase_state:)
        end
        original_purchase = create(:membership_purchase, is_archived_original_subscription_purchase: true)
        create(:membership_purchase, subscription: original_purchase.subscription, link: original_purchase.link, purchase_state: "not_charged")

        expect(Purchase.for_sales_api).to match_array [original_purchase]
      end
    end

    describe ".for_visible_posts" do
      it "returns only eligible purchases for viewing posts" do
        buyer = create(:user)
        successful_purchase = create(:purchase, purchaser: buyer, purchase_state: "successful")
        free_trial_purchase = create(:free_trial_membership_purchase, purchaser: buyer)
        gift_purchase = create(:purchase, purchase_state: "gift_receiver_purchase_successful", purchaser: buyer)
        preorder_authorization_purchase = create(:preorder_authorization_purchase, purchaser: buyer)
        membership_purchase = create(:membership_purchase, purchaser: buyer)
        physical_purchase = create(:physical_purchase, purchaser: buyer)
        create(:refunded_purchase, purchaser: buyer)
        create(:failed_purchase, purchaser: buyer)
        create(:purchase_in_progress, purchaser: buyer)
        create(:disputed_purchase, purchaser: buyer)
        create(:purchase, purchase_state: "successful")

        expect(
          Purchase.for_visible_posts(purchaser_id: buyer.id)
        ).to contain_exactly(
          successful_purchase,
          free_trial_purchase,
          gift_purchase,
          preorder_authorization_purchase,
          membership_purchase,
          physical_purchase
        )
      end
    end

    describe ".exclude_not_charged_except_free_trial" do
      it "excludes purchases that are 'not_charged' but are not free trial purchases" do
        included_purchases = %w(
          successful
          failed
          gift_receiver_purchase_successful
          preorder_authorization_successful
          test_successful
        ).map do |purchase_state|
          create(:purchase, purchase_state:)
        end
        included_purchases << create(:free_trial_membership_purchase)
        create(:purchase, purchase_state: "not_charged")
        expect(Purchase.exclude_not_charged_except_free_trial).to match_array included_purchases
      end
    end

    describe ".no_or_active_subscription" do
      it "returns non-subscription purchases and purchases with an active subscription" do
        normal_purchase = create(:purchase)
        subscription = create(:subscription)
        subscription_purchase = create(:purchase, subscription:, is_original_subscription_purchase: true)

        expect(Purchase.no_or_active_subscription).to eq([normal_purchase, subscription_purchase])
      end

      it "does not include purchases with inactive subscription" do
        normal_purchase = create(:purchase)
        subscription = create(:subscription, deactivated_at: 1.day.ago)
        create(:purchase, subscription:, is_original_subscription_purchase: true)

        expect(Purchase.no_or_active_subscription).to eq([normal_purchase])
      end
    end

    describe ".inactive_subscription" do
      it "returns subscription purchases which have been deactivated" do
        create(:purchase)
        active_subscription = create(:subscription)
        create(:purchase, subscription: active_subscription, is_original_subscription_purchase: true)
        deactivated_subscription = create(:subscription, deactivated_at: 1.day.ago)
        deactivated_subscription_purchase = create(:purchase, subscription: deactivated_subscription, is_original_subscription_purchase: true)

        expect(Purchase.inactive_subscription).to eq([deactivated_subscription_purchase])
      end
    end

    describe ".can_access_content" do
      it "includes non-subscription purchases" do
        purchase = create(:purchase)
        expect(Purchase.can_access_content).to match_array [purchase]
      end

      context "subscription purchases" do
        let(:purchase) { create(:membership_purchase) }
        let(:subscription) { purchase.subscription }

        it "includes active subscription purchases" do
          expect(Purchase.can_access_content).to match_array [purchase]
        end

        it "includes inactive subscription purchases where subscribers are allowed to access product content after the subscription has lapsed" do
          subscription.update!(deactivated_at: 1.minute.ago)
          expect(Purchase.can_access_content).to match_array [purchase]
        end

        it "excludes inactive subscription purchases if subscribers should lose access when subscription lapses" do
          subscription.update!(deactivated_at: 1.minute.ago)
          subscription.link.update!(block_access_after_membership_cancellation: true)
          expect(Purchase.can_access_content).to be_empty
        end
      end
    end
  end

  describe "lifecycle hooks" do
    describe "check perceived_price_cents_matches_price_cents" do
      let(:product) { create(:product, price_cents: 10_00) }
      let(:purchase) { build(:purchase, link: product, perceived_price_cents: 5_00) }

      it "returns false if the perceived price is different from the link price" do
        purchase.save

        expect(purchase.errors.full_messages).to include "Price cents The price just changed! Refresh the page for the updated price."
      end

      it "returns true if the purchase is_upgrade_purchase" do
        purchase.is_upgrade_purchase = true
        purchase.save

        expect(purchase.errors.full_messages).to be_empty
      end
    end
  end

  describe "not_for_sale" do
    it "doesn't allow purchases of unpublished products" do
      link = create(:product, purchase_disabled_at: Time.current)
      purchase = create(:purchase, link:, seller: link.user)
      expect(purchase.errors[:base].present?).to be(true)
      expect(purchase.error_code).to eq PurchaseErrorCode::NOT_FOR_SALE
    end

    it "allows purchases when is_commission_completion_purchase is true even if product is unpublished" do
      link = create(:product, purchase_disabled_at: Time.current)
      purchase = create(:purchase, link:, seller: link.user, is_commission_completion_purchase: true)
      expect(purchase.errors[:base].present?).to be(false)
      expect(purchase.error_code).to be_nil
    end
  end

  describe "temporarily blocked product" do
    before do
      Feature.activate(:block_purchases_on_product)

      @product = create(:product)

      BlockedObject.block!(
        BLOCKED_OBJECT_TYPES[:product],
        @product.id,
        nil,
        expires_in: 6.hours
      )
    end

    context "when the price is zero" do
      before { @product.price_cents = 0 }

      it "allows the purchase of temporarily blocked products" do
        purchase = create(:purchase, price_cents: 0, link: @product)

        expect(purchase.purchase_state).to eq "successful"
        expect(purchase.error_code).to be_blank
      end
    end

    context "when the price is not zero" do
      it "doesn't allow purchases of temporarily blocked products" do
        purchase = create(:purchase, link: @product)

        expect(purchase.errors[:base].present?).to be(true)
        expect(purchase.error_code).to eq PurchaseErrorCode::TEMPORARILY_BLOCKED_PRODUCT
        expect(purchase.errors.full_messages).to include "Your card was not charged."
      end
    end
  end

  describe "sold_out" do
    it "doesn't allow purchase once sold out" do
      link = create(:product, max_purchase_count: 1)
      create(:purchase, link:, seller: link.user)
      p2 = create(:purchase, link:, purchase_state: "in_progress")
      expect(p2.errors[:base].present?).to be(true)
      expect(p2.error_code).to eq PurchaseErrorCode::PRODUCT_SOLD_OUT
    end

    it "doesn't count failed purchases towards the sold-out count" do
      link = create(:product, max_purchase_count: 1)
      create(:purchase, link:, purchase_state: "failed")
      p2 = create(:purchase, link:)
      expect(p2).to be_valid
      p3 = create(:purchase, link:, purchase_state: "in_progress")
      expect(p3.errors[:base].present?).to be(true)
      expect(p3.error_code).to eq PurchaseErrorCode::PRODUCT_SOLD_OUT
    end

    it "allows saving a purchase when sold out" do
      link = create(:product, max_purchase_count: 1)
      purchase = create(:purchase, link:, seller: link.user)
      purchase.email = "testingtesting123@example.org"
      expect(purchase.save).to be(true)
    end

    it "doesn't count additional contributions toward max_purchase_count" do
      link = create(:product, max_purchase_count: 1)
      create(:purchase, link:, seller: link.user)
      p2 = create(:purchase, link:, is_additional_contribution: true)
      expect(p2).to be_valid
      p3 = create(:purchase, link:)
      expect(p3.errors[:base].present?).to be(true)
      expect(p3.error_code).to eq PurchaseErrorCode::PRODUCT_SOLD_OUT
    end

    it "doesn't allow purchase once sold out" do
      product = create(:product, max_purchase_count: 1)
      create(:purchase, link: product)
      purchase_2 = create(:purchase, link: product, purchase_state: "in_progress")
      expect(purchase_2.errors[:base].present?).to be(true)
      expect(purchase_2.error_code).to eq PurchaseErrorCode::PRODUCT_SOLD_OUT
    end

    describe "subscriptions" do
      before do
        @product = create(:membership_product, subscription_duration: :monthly, max_purchase_count: 1)
        @purchase = create(:purchase, link: @product, subscription: create(:subscription, link: @product), is_original_subscription_purchase: true)
      end

      it "does not count recurring charges towards the max_purchase_count" do
        @recurring_charge = build(:purchase, is_original_subscription_purchase: false, subscription: create(:subscription, link: @product), link: @product)
        expect(@recurring_charge).to be_valid
      end

      it "does count original_subscription_purchase towards max_purchase_count" do
        @purchase = create(:purchase, link: @product, subscription: create(:subscription), is_original_subscription_purchase: true)
        expect(@purchase.errors[:base].present?).to be(true)
        expect(@purchase.error_code).to eq PurchaseErrorCode::PRODUCT_SOLD_OUT
      end
    end
  end

  describe "variants_available" do
    before :each do
      @product = create(:product)
      @variant_category = create(:variant_category, link: @product)
      @variant1 = create(:variant, variant_category: @variant_category, max_purchase_count: 2)
      @variant2 = create(:variant, variant_category: @variant_category)
    end

    it "succeeds when all variants are available for the given quantities" do
      purchase = create(:purchase, link: @product, variant_attributes: [@variant1, @variant2])
      expect(purchase.errors).to be_blank
    end

    it "fails if at least one variant is not available for the given quantity" do
      purchase = create(:purchase, link: @product, variant_attributes: [@variant1, @variant2], quantity: 3)
      expect(purchase.errors.full_messages).to include "You have chosen a quantity that exceeds what is available."
    end

    it "fails if at least one variant is unavailable because it is deleted" do
      @variant2.mark_deleted!
      purchase = create(:purchase, link: @product, variant_attributes: [@variant1, @variant2])
      expect(purchase.errors.full_messages).to include "Sold out, please go back and pick another option."
    end

    it "fails if at least one variant is unavailable because it is sold out" do
      create(:purchase, link: @product, variant_attributes: [@variant1], quantity: 2)
      purchase = create(:purchase, link: @product, variant_attributes: [@variant1, @variant2])
      expect(purchase.errors.full_messages).to include "Sold out, please go back and pick another option."
    end

    context "when original_variant_attributes is set" do
      it "succeeds even when an original variant is sold out or marked deleted" do
        purchase = create(:purchase, link: @product, variant_attributes: [@variant1, @variant2], quantity: 2)
        @variant1.update!(max_purchase_count: 2)
        @variant2.mark_deleted!

        purchase.original_variant_attributes = [@variant1, @variant2]
        purchase.save
        expect(purchase.errors).to be_blank
      end

      it "fails when at least one new variant is sold out" do
        variant3 = create(:variant, variant_category: @variant_category, max_purchase_count: 1)
        create(:purchase, link: @product, variant_attributes: [variant3])

        purchase = build(:purchase, link: @product, variant_attributes: [@variant1, @variant2, variant3])
        purchase.original_variant_attributes = [@variant1, @variant2]
        purchase.save
        expect(purchase.errors.full_messages).to include "Sold out, please go back and pick another option."
      end
    end
  end

  describe "#as_json" do
    before do
      @purchase = create(:purchase, chargeback_date: 1.minute.ago, full_name: "Sahil Lavingia", email: "sahil@gumroad.com")
    end

    it "has the right keys" do
      %i[price gumroad_fee seller_id link_name timestamp daystamp chargedback paypal_refund_expired].each do |key|
        expect(@purchase.as_json.key?(key)).to be(true)
      end

      expect(@purchase.as_json[:email]).to eq "sahil@gumroad.com"
      expect(@purchase.as_json[:full_name]).to eq "Sahil Lavingia"
    end

    it "returns paypal_refund_expired as true for unrefundable PayPal purchases and false for others" do
      @unrefundable_paypal_purchase = create(:purchase, created_at: 7.months.ago, card_type: CardType::PAYPAL)
      expect(@purchase.as_json[:paypal_refund_expired]).to be(false)
      expect(@unrefundable_paypal_purchase.as_json[:paypal_refund_expired]).to be(true)
    end

    it "has the right seller_id" do
      seller = @purchase.link.user
      expect(@purchase.as_json[:seller_id]).to eq(ObfuscateIds.encrypt(seller.id))
    end

    it "has the right gumroad_fee" do
      expect(@purchase.as_json[:gumroad_fee]).to eq(93) # 10c (10%) + 50c + 3c (2.9% cc fee) + 30c (fixed cc fee)
      @purchase.update!(price_cents: 500)
      @purchase.send(:calculate_fees)
      expect(@purchase.as_json[:gumroad_fee]).to eq(145) # 50c (10%) + 50c + 15c (2.9% cc fee) + 30c (fixed cc fee)
    end

    it "has the purchaser_id if one exists" do
      expect(@purchase.as_json.key?(:purchaser_id)).to be(false)

      purchaser = create(:user)
      @purchase.update!(purchaser_id: purchaser.id)

      expect(@purchase.as_json[:purchaser_id]).to eq(purchaser.external_id)
    end

    it "has the right daystamp" do
      day = 1.day.ago
      @purchase.seller.update_attribute(:timezone, "Pacific Time (US & Canada)")
      @purchase.update_attribute(:created_at, day)
      expect(@purchase.as_json[:daystamp]).to eq day.in_time_zone("Pacific Time (US & Canada)").to_fs(:long_formatted_datetime)
    end

    it "has the right iso2 code for the country" do
      @purchase.update_attribute(:country, "United States")
      expect(@purchase.as_json[:country_iso2]).to eq "US"
    end

    it "performs a safe country code lookup for a GeoIp2 country that isn't found in IsoCountryCodes" do
      @purchase.update!(country: "South Korea")
      expect(@purchase.as_json[:country]).to eq("South Korea")
      expect(@purchase.as_json[:country_iso2]).to eq "KR"
    end

    it "returns country and state as is if they are set" do
      @purchase.update!(country: "United States", state: "CA")
      expect(@purchase.as_json[:country]).to eq("United States")
      expect(@purchase.as_json[:state]).to eq("CA")
    end

    it "returns country and state based on ip_address if they don't exist" do
      @purchase.update!(ip_address: "199.241.200.176")
      expect(@purchase.country).to eq(nil)
      expect(@purchase.state).to eq(nil)
      expect(@purchase.as_json[:country]).to eq("United States")
      expect(@purchase.as_json[:state]).to eq("CA")
    end

    it "does not have sku id if not sku exists but product is sku enabled" do
      @purchase.link.update_attribute(:skus_enabled, true)
      expect(@purchase.as_json[:sku_id]).to be_nil
    end

    it "contains receipt_url only when include_receipt_url is set" do
      receipt_url = @purchase.receipt_url
      expect(@purchase.as_json[:receipt_url]).to be nil
      expect(@purchase.as_json(include_receipt_url: true)[:receipt_url]).to eq receipt_url
    end

    it "contains `can_ping` only when `include_ping` is set" do
      expect(@purchase.as_json.key?(:can_ping)).to eq(false)
    end

    it "returns the correct value for `can_ping` when the user has notification endpoint set" do
      seller = @purchase.link.user
      seller.update!(notification_endpoint: "http://test/")

      with_can_ping_json = @purchase.as_json(include_ping: true)
      expect(with_can_ping_json[:can_ping]).to eq(true)
    end

    it "returns the correct value for `can_ping` when the user has an oauth app" do
      seller = @purchase.link.user
      seller.update!(notification_endpoint: nil)
      sub = create(:resource_subscription, user: seller, resource_name: ResourceSubscription::SALE_RESOURCE_NAME)
      Doorkeeper::AccessToken.create!(application_id: sub.oauth_application.id, resource_owner_id: seller.id, scopes: "view_sales")

      with_can_ping_json_oauth = @purchase.as_json(include_ping: true)
      expect(with_can_ping_json_oauth.key?(:can_ping)).to eq(true)
      expect(with_can_ping_json_oauth[:can_ping]).to eq(true)
    end

    it "returns the provided override for `can_ping` if provided" do
      seller = @purchase.link.user
      seller.update!(notification_endpoint: "http://test/")
      with_can_ping_cached_json = @purchase.as_json(include_ping: { value: false })

      expect(with_can_ping_cached_json.key?(:can_ping)).to eq(true)
      expect(with_can_ping_cached_json[:can_ping]).to eq(false)
    end

    it "returns the correct value for `recurring_charge`" do
      # A regular purchase
      expect(@purchase.as_json).not_to have_key(:recurring_charge)

      # The first purchase of a subscription product
      link = create(:membership_product, user: @purchase.link.user, subscription_duration: :monthly)
      subscription = create(:subscription, user: @purchase.link.user, link:)
      purchase = create(:purchase, link:, price_cents: link.price_cents, is_original_subscription_purchase: true,
                                   subscription:)
      expect(purchase.as_json[:recurring_charge]).to eq(false)

      # The second(automatic) purchase of a subscription product
      purchase = create(:purchase, link:, price_cents: link.price_cents, is_original_subscription_purchase: false,
                                   subscription:)
      expect(purchase.as_json[:recurring_charge]).to eq(true)
    end

    it "returns information about the product" do
      expect(@purchase.as_json).to have_key(:product_permalink)
      expect(@purchase.as_json).to have_key(:product_name)
      expect(@purchase.as_json).to have_key(:product_has_variants)
    end

    it "doesn't set the card expiry month and year fields" do
      purchase = create(:purchase, card_expiry_month: 11, card_expiry_year: 2022)

      expect(purchase.as_json[:card][:expiry_month]).to be_nil
      expect(purchase.as_json[:card][:expiry_year]).to be_nil
    end

    it "returns the dispute information" do
      # Assert that the response has dispute_won and disputed = false
      @purchase.update!(chargeback_date: nil)
      expect(@purchase.as_json).to include(disputed: false, dispute_won: false)

      # Mark purchase as disputed
      @purchase.update!(chargeback_date: Time.current)
      expect(@purchase.reload.as_json).to include(disputed: true, dispute_won: false)

      # Mark purchase as dispute reversed
      @purchase.update!(chargeback_reversed: true)
      expect(@purchase.reload.as_json).to include(disputed: true, dispute_won: true)
    end

    it "includes relevant flags" do
      @purchase.update!(preorder: create(:preorder))

      expect(@purchase.as_json[:is_preorder_authorization]).to eq(false)
      expect(@purchase.as_json[:is_additional_contribution]).to eq(false)
      expect(@purchase.as_json[:discover_fee_charged]).to eq(false)
      expect(@purchase.as_json[:is_gift_sender_purchase]).to eq(false)
      expect(@purchase.as_json[:is_gift_receiver_purchase]).to eq(false)
      expect(@purchase.as_json[:is_upgrade_purchase]).to eq(false)
    end

    it "falls back to the purchaser's name if full_name is blank" do
      @purchase.update! full_name: "", purchaser: create(:user, name: "Mr Gumroadson")

      expect(@purchase.as_json[:full_name]).to eq("Mr Gumroadson")
    end

    context "when the product is of type subscription" do
      context "but not a tiered membership" do
        before do
          user = @purchase.link.user
          @product = create(:subscription_product, user:, price_cents: 1000, subscription_duration: :monthly)
          @monthly_subscription = create(:subscription, user:, link: @product)
          yearly_price = create(:price, link: @product, price_cents: 10_000, recurrence: BasePrice::Recurrence::YEARLY)
          @yearly_subscription = create(:subscription, user:, link: @product)
          payment_option = @yearly_subscription.payment_options.first
          payment_option.price = yearly_price
          payment_option.save!
          @yearly_subscription.reload
        end

        it "returns the correct value for `subscription_duration` when the default subscription period is opted for" do
          # The first purchase of a subscription product
          purchase = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription: @monthly_subscription)
          expect(purchase.as_json[:subscription_duration]).to eq("monthly")

          # The second (automatic) purchase of a subscription product
          purchase = create(:purchase, link: @product, is_original_subscription_purchase: false, subscription: @monthly_subscription)
          expect(purchase.as_json[:subscription_duration]).to eq("monthly")
        end

        it "returns the correct value for `subscription_duration` when a non-default subscription period is opted for" do
          # The first purchase of a subscription product
          purchase = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription: @yearly_subscription)
          expect(purchase.as_json[:subscription_duration]).to eq("yearly")

          # The second (automatic) purchase of a subscription product
          purchase = create(:purchase, link: @product, is_original_subscription_purchase: false, subscription: @yearly_subscription)
          expect(purchase.as_json[:subscription_duration]).to eq("yearly")
        end
      end

      context "and is a tiered membership" do
        before do
          user = @purchase.link.user
          recurrence_price_values = [
            {
              BasePrice::Recurrence::MONTHLY => { enabled: true, price: 10 },
              BasePrice::Recurrence::YEARLY => { enabled: true, price: 100 }
            },
            {
              BasePrice::Recurrence::MONTHLY => { enabled: true, price: 2 },
              BasePrice::Recurrence::YEARLY => { enabled: true, price: 2 }
            }
          ]
          @product = create(:membership_product_with_preset_tiered_pricing, recurrence_price_values:)
          yearly_price = @product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::YEARLY)
          @monthly_subscription = create(:subscription, user:, link: @product)
          @yearly_subscription = create(:subscription, user:, link: @product)
          payment_option = @yearly_subscription.payment_options.first
          payment_option.price = yearly_price
          payment_option.save!
          @yearly_subscription.reload
        end

        it "returns the correct value for `subscription_duration` when the default subscription period is opted for" do
          # The first purchase of a subscription product
          purchase = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription: @monthly_subscription)
          expect(purchase.as_json[:subscription_duration]).to eq("monthly")

          # The second (automatic) purchase of a subscription product
          purchase = create(:purchase, link: @product, is_original_subscription_purchase: false, subscription: @monthly_subscription)
          expect(purchase.as_json[:subscription_duration]).to eq("monthly")
        end

        it "returns the correct value for `subscription_duration` when a non-default subscription period is opted for" do
          # The first purchase of a subscription product
          purchase = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription: @yearly_subscription)
          expect(purchase.as_json[:subscription_duration]).to eq("yearly")

          # The second (automatic) purchase of a subscription product
          purchase = create(:purchase, link: @product, is_original_subscription_purchase: false, subscription: @yearly_subscription)
          expect(purchase.as_json[:subscription_duration]).to eq("yearly")
        end

        context "and has a free trial" do
          before do
            @free_trial_ends_at = 1.day.ago
            @monthly_subscription.update!(free_trial_ends_at: @free_trial_ends_at)
            @purchase = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription: @monthly_subscription)
          end

          it "returns the formatted free trial end date" do
            expect(@purchase.as_json[:free_trial_ends_on]).to eq @free_trial_ends_at.to_fs(:formatted_date_abbrev_month)
          end

          it "includes whether the free trial has ended" do
            expect(@purchase.as_json[:free_trial_ended]).to eq true
          end
        end
      end
    end

    it "does not contain `subscription_duration` in the return value for a product which is not of type subscription" do
      expect(@purchase.as_json).not_to have_key(:subscription_duration)
    end

    context "with include_variant_details: true" do
      it "includes variant details regardless of skus_enabled" do
        product = @purchase.link
        category = create(:variant_category, link: product, title: "Color")
        blue_variant = create(:variant, variant_category: category, name: "Blue")
        @purchase.variant_attributes << blue_variant
        @purchase.save!
        @purchase.link.update!(skus_enabled: true)

        variants_json = @purchase.reload.as_json(include_variant_details: true)[:variants]

        expect(variants_json).to eq(
          category.external_id => {
            title: category.title,
            selected_variant: {
              id: blue_variant.external_id,
              name: blue_variant.name
            }
          }
                                 )
      end

      it "includes SKU details regardless of skus_enabled" do
        product = @purchase.link
        category_1 = create(:variant_category, link: product, title: "Color")
        category_2 = create(:variant_category, link: product, title: "Size")
        sku_title = "#{category_1.title} - #{category_2.title}"
        sku = create(:sku, link: product, name: "Blue - large")
        @purchase.variant_attributes << sku
        @purchase.save!
        @purchase.reload

        variants_json = @purchase.as_json(include_variant_details: true)[:variants]

        expect(variants_json).to eq(
          sku_title => {
            is_sku: true,
            title: sku_title,
            selected_variant: {
              id: sku.external_id,
              name: sku.name
            }
          }
                                 )
      end

      it "includes empty hashes if no variants" do
        variants_json = @purchase.as_json(include_variant_details: true)[:variants]

        expect(variants_json).to eq({})
      end
    end

    context "with creator_app_api: true" do
      it "includes the product's thumbnail url, if present" do
        json = @purchase.as_json(creator_app_api: true)
        expect(json.key?(:product_thumbnail_url)).to eq(true)
        expect(json[:product_thumbnail_url]).to eq(nil)

        thumbnail = create(:thumbnail, product: @purchase.link)
        json = @purchase.reload.as_json(creator_app_api: true)
        expect(json[:product_thumbnail_url]).to eq(thumbnail.url)
      end

      it "includes price & formatted_total_price" do
        purchase = create(:purchase, price_cents: 400, displayed_price_cents: 300)
        json = purchase.as_json(creator_app_api: true)
        expect(json[:price]).to eq("$3")
        expect(json[:formatted_total_price]).to eq("$4")
      end

      it "includes the refund state" do
        purchase = create(:purchase) # stripe_refunded => nil
        json = purchase.as_json(creator_app_api: true)
        expect(json[:refunded]).to eq(false)

        purchase = create(:purchase, stripe_refunded: false)
        json = purchase.as_json(creator_app_api: true)
        expect(json[:refunded]).to eq(false)

        purchase = create(:purchase, stripe_refunded: true)
        json = purchase.as_json(creator_app_api: true)
        expect(json[:refunded]).to eq(true)

        purchase = create(:purchase) # stripe_partially_refunded => false
        json = purchase.as_json(creator_app_api: true)
        expect(json[:partially_refunded]).to eq(false)

        purchase = create(:purchase, stripe_partially_refunded: true)
        json = purchase.as_json(creator_app_api: true)
        expect(json[:partially_refunded]).to eq(true)
      end

      it "includes the chargeback state" do
        purchase = create(:purchase)
        json = purchase.as_json(creator_app_api: true)
        expect(json[:chargedback]).to eq(false)

        purchase.update!(chargeback_date: Time.current)
        json = purchase.as_json(creator_app_api: true)
        expect(json[:chargedback]).to eq(true)

        purchase.update!(chargeback_reversed: true)
        json = purchase.as_json(creator_app_api: true)
        expect(json[:chargedback]).to eq(false)
      end
    end

    context "with query" do
      it "returns paypal_email when it matches query" do
        paypal_email = "jane@paypal.com"
        @purchase.update!(card_visual: paypal_email)

        expect(@purchase.as_json(query: paypal_email)[:paypal_email]).to eq(paypal_email)
      end

      it "does not return paypal_email when it matches query but not an email" do
        query = "test_card"
        @purchase.update!(card_visual: query)

        expect(@purchase.as_json(query:)[:paypal_email]).to be_nil
      end

      it "does not return paypal_email when it does not match a query" do
        paypal_email = "jane@paypal.com"
        @purchase.update!(card_visual: paypal_email)

        expect(@purchase.as_json(query: "xxx")[:paypal_email]).to be_nil
      end
    end

    context "with pundit_user" do
      let(:user) { create(:user) }
      let(:seller) { @purchase.seller }
      let(:pundit_user) { SellerContext.new(user:, seller:) }

      before do
        create(:team_membership, user:, seller:, role: TeamMembership::ROLE_ADMIN)
      end

      it "contains `can_revoke_access` and `can_undo_revoke_access`" do
        hash_data = @purchase.as_json(pundit_user:)
        expect(hash_data[:can_revoke_access]).to eq(true)
        expect(hash_data[:can_undo_revoke_access]).to eq(false)
      end
    end

    describe "upsells" do
      context "when there isn't an upsell purchase" do
        it "doesn't include upsell information" do
          expect(@purchase.as_json[:upsell]).to be_nil
        end
      end

      context "when there is an upsell purchase" do
        it "includes upsell information" do
          upsell_purchase = create(:upsell_purchase)
          expect(upsell_purchase.purchase.as_json[:upsell]).to eq(upsell_purchase.as_json)
        end
      end
    end

    describe "when the purchase was recommended by more like this" do
      it "returns true for is_more_like_this_recommended" do
        @purchase.update(recommended_by: RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION)
        expect(@purchase.as_json[:is_more_like_this_recommended]).to eq(true)
      end
    end

    context "with custom fields" do
      it "returns the correct format for version 1" do
        @purchase.purchase_custom_fields << build(:purchase_custom_field, name: "custom", value: "value")
        @purchase.purchase_custom_fields << build(:purchase_custom_field, name: "boolean", value: "true", type: CustomField::TYPE_CHECKBOX)
        expect(@purchase.as_json[:custom_fields]).to eq(["custom: value", "boolean: true"])
      end

      it "returns the correct format for version 2" do
        @purchase.purchase_custom_fields << build(:purchase_custom_field, name: "custom", value: "value")
        @purchase.purchase_custom_fields << build(:purchase_custom_field, name: "boolean", value: "true", type: CustomField::TYPE_CHECKBOX)
        expect(@purchase.as_json(version: 2)[:custom_fields]).to eq({ "custom" => "value", "boolean" => true })
      end
    end
  end

  it "allows > $1000 if seller is verified" do
    expect(build(:purchase, link: create(:product, user: create(:user, verified: true)), price_cents: 100_100)).to be_valid
  end

  it "has an address and name when the link requires it" do
    purchase = build(:purchase, street_address: nil, link: create(:product, require_shipping: true))
    expect(purchase).to_not be_valid
    %i[full_name street_address country state city zip_code].each do |w|
      expect(purchase.errors[w].length).to eq(1)
    end
  end

  describe "limiting # of sales for a link" do
    let(:user) { create(:user) }
    let(:link) { create(:product, max_purchase_count: 1) }
    let(:purchase1) { create(:purchase, link:) }
    let(:purchase2) { create(:purchase_2, link:) }

    describe "no purchases exist" do
      it "increments purchase count" do
        expect do
          purchase1.save!
        end.to change { Purchase.count }.by(1)
      end
    end

    describe "max purchase limit reached" do
      before { purchase1.save! }

      describe "purchase limit is then raised" do
        let(:link) { create(:product, max_purchase_count: 10) }

        it "increments count" do
          expect do
            purchase2.save!
          end.to change { Purchase.count }.by(1)
        end
      end
    end
  end

  describe "mongoable" do
    it "puts purchase in mongo on creation" do
      @purchase = build(:purchase)
      @purchase.save

      expect(SaveToMongoWorker).to have_enqueued_sidekiq_job("Purchase", anything)
    end
  end

  describe "affiliate_merchant_account" do
    describe "purchase is on a Gumroad merchant account" do
      let(:purchase) { create(:purchase) }

      it "returns a Gumroad merchant account" do
        expect(purchase.affiliate_merchant_account.user_id).to eq(nil)
      end

      it "returns a merchant account that matches the charge processor of the purchase" do
        expect(purchase.affiliate_merchant_account.charge_processor_id).to eq(purchase.charge_processor_id)
      end
    end

    describe "purchase is on a creator's merchant account" do
      let(:purchase) { create(:purchase, merchant_account: create(:merchant_account)) }

      it "returns a Gumroad merchant account" do
        expect(purchase.affiliate_merchant_account.user_id).to eq(nil)
      end

      it "returns a merchant account that matches the charge processor of the purchase" do
        expect(purchase.affiliate_merchant_account.charge_processor_id).to eq(purchase.charge_processor_id)
      end
    end
  end

  describe "tax_label" do
    describe "GST" do
      let(:au_tax_rate) { create(:zip_tax_rate, country: "AU", combined_rate: 0.1) }
      let(:sg_tax_rate) { create(:zip_tax_rate, country: "SG", combined_rate: 0.07) }
      let(:purchase_au) { create(:purchase, price_cents: 100, total_transaction_cents: 110, gumroad_tax_cents: 10, zip_tax_rate: au_tax_rate) }
      let(:purchase_sg) { create(:purchase, price_cents: 100, total_transaction_cents: 107, gumroad_tax_cents: 7, zip_tax_rate: sg_tax_rate) }

      context "when include_tax_rate is true" do
        it "returns GST with percentage for Australia" do
          expect(purchase_au.tax_label).to eq("GST (10%)")
        end

        it "returns GST with percentage for Singapore" do
          expect(purchase_sg.tax_label).to eq("GST (7%)")
        end
      end

      context "when include_tax_rate is false" do
        it "returns GST without percentage" do
          expect(purchase_au.tax_label(include_tax_rate: false)).to eq("GST")
          expect(purchase_sg.tax_label(include_tax_rate: false)).to eq("GST")
        end
      end
    end

    describe "VAT" do
      let(:eu_tax_rate) { create(:zip_tax_rate, country: "DE", combined_rate: 0.19) }
      let(:norway_tax_rate) { create(:zip_tax_rate, country: "NO", combined_rate: 0.25) }
      let(:japan_tax_rate) { create(:zip_tax_rate, country: "JP", combined_rate: 0.1) }
      let(:digital_tax_rate) { create(:zip_tax_rate, country: "BY", combined_rate: 0.2) }

      let(:eu_purchase) { create(:purchase, price_cents: 100, total_transaction_cents: 119, gumroad_tax_cents: 19, zip_tax_rate: eu_tax_rate) }
      let(:norway_purchase) { create(:purchase, price_cents: 100, total_transaction_cents: 125, gumroad_tax_cents: 25, zip_tax_rate: norway_tax_rate) }
      let(:japan_purchase) { create(:purchase, price_cents: 100, total_transaction_cents: 110, gumroad_tax_cents: 10, zip_tax_rate: japan_tax_rate) }
      let(:digital_purchase) { create(:purchase, price_cents: 100, total_transaction_cents: 120, gumroad_tax_cents: 20, zip_tax_rate: digital_tax_rate) }

      context "when include_tax_rate is true" do
        it "returns VAT with percentage for EU countries" do
          expect(eu_purchase.tax_label).to eq("VAT (19%)")
        end

        it "returns VAT with percentage for Norway" do
          expect(norway_purchase.tax_label).to eq("VAT (25%)")
        end

        it "returns VAT with percentage for countries that collect tax on all products" do
          expect(japan_purchase.tax_label).to eq("VAT (10%)")
        end

        it "returns VAT with percentage for countries that collect tax on digital products" do
          expect(digital_purchase.tax_label).to eq("VAT (20%)")
        end

        it "rounds down the percentage" do
          tax_rate = create(:zip_tax_rate, country: "DE", combined_rate: 0.196)
          purchase = create(:purchase, price_cents: 100, total_transaction_cents: 119, gumroad_tax_cents: 19, zip_tax_rate: tax_rate)
          expect(purchase.tax_label).to eq("VAT (19%)")
        end
      end

      context "when include_tax_rate is false" do
        it "returns VAT without percentage" do
          expect(eu_purchase.tax_label(include_tax_rate: false)).to eq("VAT")
          expect(norway_purchase.tax_label(include_tax_rate: false)).to eq("VAT")
          expect(japan_purchase.tax_label(include_tax_rate: false)).to eq("VAT")
          expect(digital_purchase.tax_label(include_tax_rate: false)).to eq("VAT")
        end
      end
    end

    describe "Sales tax" do
      let(:us_tax_rate) { create(:zip_tax_rate, country: "US", combined_rate: 0.08) }
      let(:ca_tax_rate) { create(:zip_tax_rate, country: "CA", combined_rate: 0.13) }
      let(:other_tax_rate) { create(:zip_tax_rate, country: "BR", combined_rate: 0.15) }

      context "when include_tax_rate is true" do
        context "when was_tax_excluded_from_price is true" do
          it "returns 'Sales tax' for US" do
            purchase = create(:purchase, price_cents: 108, total_transaction_cents: 108, tax_cents: 8, zip_tax_rate: us_tax_rate, was_tax_excluded_from_price: true)
            expect(purchase.tax_label).to eq("Sales tax")
          end

          it "returns 'Sales tax' for Canada" do
            purchase = create(:purchase, price_cents: 113, total_transaction_cents: 113, tax_cents: 13, zip_tax_rate: ca_tax_rate, was_tax_excluded_from_price: true)
            expect(purchase.tax_label).to eq("Sales tax")
          end

          it "returns 'Sales tax' for other countries" do
            purchase = create(:purchase, price_cents: 115, total_transaction_cents: 115, tax_cents: 15, zip_tax_rate: other_tax_rate, was_tax_excluded_from_price: true)
            expect(purchase.tax_label).to eq("Sales tax")
          end
        end

        context "when was_tax_excluded_from_price is false" do
          it "returns 'Sales tax (included)' for US" do
            purchase = create(:purchase, price_cents: 100, total_transaction_cents: 100, tax_cents: 8, zip_tax_rate: us_tax_rate, was_tax_excluded_from_price: false)
            expect(purchase.tax_label).to eq("Sales tax (included)")
          end

          it "returns 'Sales tax (included)' for Canada" do
            purchase = create(:purchase, price_cents: 100, total_transaction_cents: 100, tax_cents: 13, zip_tax_rate: ca_tax_rate, was_tax_excluded_from_price: false)
            expect(purchase.tax_label).to eq("Sales tax (included)")
          end

          it "returns 'Sales tax (included)' for other countries" do
            purchase = create(:purchase, price_cents: 100, total_transaction_cents: 100, tax_cents: 15, zip_tax_rate: other_tax_rate, was_tax_excluded_from_price: false)
            expect(purchase.tax_label).to eq("Sales tax (included)")
          end
        end
      end

      context "when include_tax_rate is false" do
        it "returns 'Sales tax' regardless of was_tax_excluded_from_price" do
          included_purchase = create(:purchase, price_cents: 100, total_transaction_cents: 100, tax_cents: 8, zip_tax_rate: us_tax_rate, was_tax_excluded_from_price: false)
          excluded_purchase = create(:purchase, price_cents: 108, total_transaction_cents: 108, tax_cents: 8, zip_tax_rate: us_tax_rate, was_tax_excluded_from_price: true)

          expect(included_purchase.tax_label(include_tax_rate: false)).to eq("Sales tax")
          expect(excluded_purchase.tax_label(include_tax_rate: false)).to eq("Sales tax")
        end
      end
    end

    describe "edge cases" do
      it "returns nil when has_tax_label? is false" do
        purchase = create(:purchase, price_cents: 100, total_transaction_cents: 100, was_purchase_taxable: false, gumroad_tax_cents: 0, tax_cents: 0)
        expect(purchase.tax_label).to be_nil
      end

      it "defaults to 'Sales tax (included)' when zip_tax_rate is nil" do
        purchase = create(:purchase, price_cents: 100, total_transaction_cents: 120, gumroad_tax_cents: 20, zip_tax_rate: nil)
        expect(purchase.tax_label).to eq("Sales tax (included)")
      end

      it "uses tax_cents when gumroad_tax_cents is 0" do
        tax_rate = create(:zip_tax_rate, country: "DE", combined_rate: 0.19)
        purchase = create(:purchase, price_cents: 100, total_transaction_cents: 119, gumroad_tax_cents: 0, tax_cents: 19, zip_tax_rate: tax_rate, was_purchase_taxable: true)
        expect(purchase.tax_label).to eq("VAT (19%)")
      end
    end
  end

  describe "tax_label_with_creator_tax_info" do
    let(:purchase) { create(:purchase) }

    describe "purchase without any tax rate attached to it" do
      it "defers to #tax_label" do
        expect(purchase).to receive(:tax_label)
        purchase.tax_label_with_creator_tax_info
      end

      it "returns nil" do
        expect(purchase.tax_label_with_creator_tax_info).to be(nil)
      end
    end

    describe "purchase with zip tax rate" do
      let(:zip_tax_rate) { create(:zip_tax_rate) }

      before do
        zip_tax_rate.purchases << purchase
        zip_tax_rate.save!
      end

      describe "without an user association" do
        let(:purchase) { create(:purchase, gumroad_tax_cents: 100) }

        it "defers to #tax_label" do
          expect(purchase).to receive(:tax_label)
          purchase.tax_label_with_creator_tax_info
        end

        it "returns #tax_label's result" do
          expect(purchase.tax_label_with_creator_tax_info).to eq(purchase.tax_label)
        end
      end

      describe "with a user association but no invoice_sales_tax_id" do
        let(:purchase) { create(:purchase, tax_cents: 100) }

        before do
          zip_tax_rate.user_id = create(:user).id
          zip_tax_rate.save!
        end

        it "defers to #tax_label" do
          expect(purchase).to receive(:tax_label)
          purchase.tax_label_with_creator_tax_info
        end

        it "returns #tax_label's result" do
          expect(purchase.tax_label_with_creator_tax_info).to eq(purchase.tax_label)
        end
      end

      describe "with a user association and invoice_sales_tax_id" do
        let(:purchase) { create(:purchase, gumroad_tax_cents: 100) }

        before do
          zip_tax_rate.user_id = create(:user).id
          zip_tax_rate.invoice_sales_tax_id = "dummy tax ID"
          zip_tax_rate.save!
        end

        it "appends the tax ID to the tax_label result" do
          expected_tax_label = purchase.tax_label + " (Creator tax ID: #{purchase.zip_tax_rate.invoice_sales_tax_id})"
          expect(purchase).to receive(:tax_label).and_call_original
          expect(purchase.tax_label_with_creator_tax_info).to eq(expected_tax_label)
        end
      end
    end
  end

  describe "#sync_status_with_charge_processor" do
    it "calls Purchase::SyncStatusWithChargeProcessorService for the purchase" do
      purchase = create(:purchase)
      expect(Purchase::SyncStatusWithChargeProcessorService).to receive(:new).with(purchase, mark_as_failed: true).and_call_original
      expect_any_instance_of(Purchase::SyncStatusWithChargeProcessorService).to receive(:perform)
      purchase.sync_status_with_charge_processor(mark_as_failed: true)
    end
  end

  describe "#find_enabled_integration" do
    let(:discord_integration) { create(:discord_integration) }
    let(:circle_integration) { create(:circle_integration) }

    it "returns the enabled integration for a standalone product purchase" do
      product = create(:product, active_integrations: [discord_integration, circle_integration])
      purchase = create(:purchase, link: product)

      expect(purchase.find_enabled_integration(Integration::DISCORD)).to eq(discord_integration)
    end

    it "returns the enabled integration for a variant purchase" do
      product = create(:product_with_digital_versions, active_integrations: [discord_integration, circle_integration])
      variant = product.variant_categories_alive.first.variants.first
      variant.active_integrations << [discord_integration, circle_integration]
      purchase = create(:purchase, variant_attributes: [variant])

      expect(purchase.find_enabled_integration(Integration::DISCORD)).to eq(discord_integration)
    end

    it "returns nil if the purchased product has an enabled integration but the variant does not" do
      product = create(:product_with_digital_versions, active_integrations: [discord_integration, circle_integration])
      variants = product.variant_categories_alive.first.variants
      variant = variants.first
      variant.active_integrations << [discord_integration, circle_integration]
      purchase = create(:purchase, variant_attributes: [variants.second])

      expect(purchase.find_enabled_integration(Integration::DISCORD)).to eq(nil)
    end
  end

  describe "#perceived_price_cents" do
    before { @subject = build(:purchase) }
    describe "#perceived_price_cents nil" do
      before { @subject.perceived_price_cents = nil }

      it "can be valid because it wasn't used - mainly used in the view" do
        expect(@subject).to be_valid
      end
    end

    describe "#perceived_price_cents does not match but user set his own price for a customizable link" do
      before do
        @subject.link.customizable_price = true
        @subject.price_range = 79
        @subject.perceived_price_cents = @subject.price_cents + 10_00
      end

      it "is valid" do
        expect(@subject.link).to be_customizable_price
        expect(@subject).to be_valid
      end
    end
  end

  describe "#variant_extra_cost" do
    context "for a purchase with no variants" do
      it "returns 0" do
        purchase = create(:purchase, variant_attributes: [])
        expect(purchase.variant_extra_cost).to eq 0
      end
    end

    context "for a purchase with variants" do
      context "for a non-tiered membership product" do
        it "sums the variants' price_difference_cents" do
          product = create(:product)
          category1 = create(:variant_category, link: product)
          variant1 = create(:variant, variant_category: category1)
          category2 = create(:variant_category, link: product)
          variant2 = create(:variant, variant_category: category2, price_difference_cents: 1_00)
          category3 = create(:variant_category, link: product)
          variant3 = create(:variant, variant_category: category3, price_difference_cents: 2_00)
          purchase = create(:purchase, link: product, variant_attributes: [variant1, variant2, variant3])

          expect(purchase.variant_extra_cost).to eq 3_00
        end
      end

      context "for a tiered membership product" do
        before :each do
          recurrence_price_values = [
            { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 10 }, BasePrice::Recurrence::YEARLY => { enabled: true, price: 100 } },
            { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 5 }, BasePrice::Recurrence::YEARLY => { enabled: true, price: 50 } }
          ]
          product = create(:membership_product_with_preset_tiered_pricing, recurrence_price_values:)
          @yearly_price = product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::YEARLY)
          @tier = product.tiers.find_by!(name: "Second Tier")
          @purchase = create(:purchase, link: product, variant_attributes: [@tier], price: @yearly_price)
        end

        it "sums the price cents for the variant prices with the given recurrence" do
          expect(@purchase.variant_extra_cost).to eq 50_00
        end

        context "where a variant doesn't have prices" do
          it "returns 0, regardless of the variant's price_difference_cents" do
            @tier.prices.destroy_all
            @tier.update!(price_difference_cents: 2_00)

            expect(@purchase.variant_extra_cost).to eq 0
          end
        end

        context "where a variant has only rental prices" do
          it "returns 0" do
            @tier.prices.each do |price|
              price.is_rental = true
              price.save!
            end

            expect(@purchase.variant_extra_cost).to eq 0
          end
        end

        context "when existing price has been deleted" do
          before :each do
            @yearly_price.mark_deleted!
            @tier.prices.find_by(recurrence: BasePrice::Recurrence::YEARLY).mark_deleted!
          end

          it "returns 0 if original_price is not set" do
            expect(@purchase.variant_extra_cost).to eq 0
          end

          it "counts the deleted price if original_price is set" do
            @purchase.original_price = @yearly_price
            expect(@purchase.variant_extra_cost).to eq 50_00
          end
        end
      end
    end
  end

  describe "mass assignment" do
    it "sets price" do
      expect(Purchase.new(price_cents: 100).price_cents).to eq 1_00
    end

    it "sets total transaction amount" do
      expect(Purchase.new(total_transaction_cents: 100).total_transaction_cents).to eq 1_00
    end

    it "sets chargeable" do
      expect(Purchase.new(chargeable: ["bogart"]).chargeable).to eq ["bogart"]
    end

    it "sets perceived price" do
      expect(Purchase.new(perceived_price_cents: 100).perceived_price_cents).to eq 100
    end
  end

  describe "non-subscription" do
    before do
      @purchase = build(:purchase, purchase_state: "in_progress")
    end

    it "does not schedule recurring charge" do
      @purchase.update_balance_and_mark_successful!

      expect(RecurringChargeWorker.jobs.size).to eq(0)
    end
  end

  describe "delegation" do
    before { @subject = create(:purchase) }

    it "has seller info" do
      expect(@subject.seller_email).to eq @subject.seller.email
      expect(@subject.seller_name).to eq @subject.seller.name
    end

    it "has link info" do
      expect(@subject.link_name).to eq @subject.link.name
    end
  end

  describe "price_is_not_cheated" do
    let(:link) { create(:product, price_cents: 200) }

    subject { create(:purchase, link:, seller: link.user) }

    it "is valid if price is at or above link price" do
      subject.price_cents = 200
      expect(subject).to be_valid

      subject.price_cents = 300
      expect(subject).to be_valid
    end
  end

  describe "price_cents" do
    let(:price) { 1_00 }

    subject { create(:purchase, price_cents: price) }

    it "returns the price in cents" do
      expect(subject.price_cents).to eq 100
      expect(subject.price_cents).to be_a_kind_of(Integer)
    end
  end

  describe "total_transaction_cents" do
    let(:price) { 1_00 }

    subject { create(:purchase, total_transaction_cents: price) }

    it "returns the total transaction price in cents" do
      expect(subject.total_transaction_cents).to eq 100
      expect(subject.total_transaction_cents).to be_a_kind_of(Integer)
    end
  end

  describe "fee_cents" do
    it "gets calculated on creation" do
      purchase = create(:purchase, price_cents: 1_00)
      expect(purchase.fee_cents).to eq 93 # 10c (10%) + 3c (2.9% cc fee) + 30c (fixed cc fee)

      purchase = create(:purchase, price_cents: 2_00)
      expect(purchase.fee_cents).to eq 106 # 20c (10%) + 50c + 6c (2.9% cc fee) + 30c (fixed cc fee)

      purchase = create(:purchase, price_cents: 3_00)
      expect(purchase.fee_cents).to eq 119 # 30c (10%) + 50c + 9c (2.9% cc fee) + 30c (fixed cc fee)
    end

    it "doesn't reset the rate when it gets saved again " do
      purchase = create(:purchase, price_cents: 1_00)

      purchase.fee_cents = 20
      purchase.save

      expect(purchase.fee_cents).to eq 20
    end

    it "is 0 if merchant account is a Brazilian Stripe Connect account" do
      seller = create(:named_seller)
      product = create(:product, price_cents: 10_00, user: seller)
      purchase = create(:purchase,
                        link: product,
                        chargeable: create(:chargeable),
                        merchant_account: create(:merchant_account_stripe_connect, user: seller, country: "BR"))
      expect(purchase.fee_cents).to eq 0
    end
  end

  describe "processor_fee_cents" do
    it "gets calculated correctly" do
      purchase = create(:purchase)
      purchase.perceived_price_cents = 100
      purchase.chargeable = build(:chargeable)
      purchase.process!
      expect(purchase.processor_fee_cents).to eq 10
    end
  end

  describe "fee_dollars" do
    it "gets calculated correctly" do
      purchase = create(:purchase, price_cents: 10_00)
      expect(purchase.fee_dollars).to eq(2.09) # 100c (10%) + 50c + 29c (2.9% cc fee) + 30c (fixed cc fee)

      purchase = create(:purchase, price_cents: 15_00)
      expect(purchase.fee_dollars).to eq(2.74) # 150c (10%) + 50c + 44c (2.9% cc fee) + 30c (fixed cc fee)

      purchase = create(:purchase, price_cents: 22_00)
      expect(purchase.fee_dollars).to eq(3.64) # 220c (10%) + 50c + 64c (2.9% cc fee) + 30c (fixed cc fee)
    end
  end

  describe "payment" do
    it "is the difference between price and fee" do
      purchase = create(:purchase, price_cents: 1_00)
      expect(purchase.payment_cents).to eq 7 # calculated fee is 93c -- 10c (10%) + 50c + 3c (2.9% cc fee) + 30c (fixed cc fee)
    end
  end

  describe "save_with_payment" do
    before do
      @user = create(:user)
      @product = create(:product, user: @user)
    end

    it "doesn't hit stripe if invalid" do
      purchase = build(:purchase, link: create(:product))
      purchase.process!
      expect(purchase.errors[:base].present?).to be(true)
    end

    {
      user_suspended: ->(u, _l) { u.suspend_for_fraud },
      link_disabled: ->(_u, l) { l.purchase_disabled_at = Time.current },
      link_deleted: ->(_u, l) { l.deleted_at = Time.current }
    }.each do |k, v|
      it "does not hit stripe if #{k}" do
        v.call(@user, @product)
        @product.save!
        purchase = build(:purchase, link: @product)
        purchase.process!
        expect(purchase.errors[:base].present?).to be(true)
      end
    end
  end

  describe "#charged_using_paypal_connect_account?" do
    it "returns true if merchant account is a paypal connect account otherwise false" do
      expect(create(:purchase, merchant_account: create(:merchant_account_stripe)).charged_using_paypal_connect_account?).to be false
      expect(create(:purchase, merchant_account: create(:merchant_account_stripe_connect)).charged_using_paypal_connect_account?).to be false
      expect(create(:purchase, merchant_account: create(:merchant_account_paypal)).charged_using_paypal_connect_account?).to be true
    end
  end

  describe "tier fee" do
    def create_purchase(is_merchant: false, charge_discover_fee: false, price_cents: 0, discover_fee_per_thousand: nil)
      creator = create(:user)

      allow_any_instance_of(User).to receive(:recommendations_enabled?).and_return(charge_discover_fee)
      allow_any_instance_of(Purchase).to receive(:charged_using_gumroad_merchant_account?).and_return(is_merchant)
      allow_any_instance_of(Purchase).to receive(:flat_fee_applicable?).and_return(false)
      product = build(:product, user: creator)
      product.discover_fee_per_thousand = discover_fee_per_thousand if discover_fee_per_thousand
      product.save
      purchase = create(:purchase, link: product, was_product_recommended: charge_discover_fee, price_cents: 10_00)
      purchase
    end

    context "non-merchant account" do
      context "discover purchase" do
        it "uses correct tier fee" do
          purchase = create_purchase(charge_discover_fee: true, price_cents: 10_00)

          tier_fee = 70
          discover_fee = 200
          expect(purchase.fee_cents).to eq(tier_fee + discover_fee)
        end
      end

      context "discover ad purchase" do
        it "uses correct discover fee" do
          purchase = create_purchase(charge_discover_fee: true, price_cents: 10_00, discover_fee_per_thousand: 300)

          tier_fee = 70
          discover_fee = 200
          expect(purchase.fee_cents).to eq(tier_fee + discover_fee)
        end
      end

      context "non-discover purchase" do
        it "uses correct tier fee" do
          purchase = create_purchase(charge_discover_fee: false, price_cents: 10_00)

          tier_fee = 120
          expect(purchase.fee_cents).to eq(tier_fee)
        end
      end
    end

    context "merchant account" do
      context "discover purchase" do
        it "uses correct tier fee" do
          purchase = create_purchase(is_merchant: true, charge_discover_fee: true, price_cents: 10_00)

          tier_fee = 90
          discover_fee = 171
          expect(purchase.fee_cents).to eq(tier_fee + discover_fee)
        end
      end

      context "discover purchase" do
        it "uses correct discover fee" do
          purchase = create_purchase(is_merchant: true, charge_discover_fee: true, price_cents: 10_00, discover_fee_per_thousand: 300)

          tier_fee = 90
          discover_fee = 171
          expect(purchase.fee_cents).to eq(tier_fee + discover_fee)
        end
      end

      context "non-discover purchase" do
        it "uses correct tier fee" do
          purchase = create_purchase(is_merchant: true, charge_discover_fee: false, price_cents: 10_00)

          tier_fee = 90
          fixed_fee = 80
          expect(purchase.fee_cents).to eq(tier_fee + fixed_fee)
        end
      end
    end
  end

  describe "new flat fee" do
    before do
      @creator = create(:user)
      @product = create(:product, user: @creator, price_cents: 10_00)
    end

    context "charge on gumroad stripe account" do
      it "uses flat fee if applicable to the creator otherwise uses tier fee" do
        purchase = create(:purchase, link: @product, purchase_state: "in_progress", chargeable: create(:chargeable))
        purchase.process!

        expect(purchase.send(:flat_fee_applicable?)).to be true
        expect(purchase.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(purchase.fee_cents).to eq(209) # 100 (10pc gumroad fee) + 50c + 29 (2.9 pc stripe fee) + 30 (30c fixed stripe fee)
      end
    end

    context "charge on a custom stripe connect account" do
      it "uses flat fee if applicable to the creator otherwise uses tier fee" do
        merchant_account = create(:merchant_account, user: @creator, charge_processor_merchant_id: "acct_19paZxAQqMpdRp2I")

        purchase = create(:purchase, link: @product, purchase_state: "in_progress", chargeable: create(:chargeable))
        purchase.process!

        expect(purchase.send(:flat_fee_applicable?)).to be true
        expect(purchase.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(purchase.merchant_account).to eq(merchant_account)
        expect(purchase.fee_cents).to eq(209) # 100 (10pc gumroad fee) + 50c + 29 (2.9 pc stripe fee) + 30 (30c fixed stripe fee)
      end
    end

    context "charge on a paypal connect account" do
      it "uses flat fee if applicable to the creator otherwise uses tier fee" do
        merchant_account = create(:merchant_account_paypal, user: @creator, charge_processor_merchant_id: "CJS32DZ7NDN5L", country: "GB", currency: "gbp")

        purchase = create(:purchase, link: @product, purchase_state: "in_progress", chargeable: create(:native_paypal_chargeable))
        purchase.process!

        expect(purchase.send(:flat_fee_applicable?)).to be true
        expect(purchase.charge_processor_id).to eq(PaypalChargeProcessor.charge_processor_id)
        expect(purchase.merchant_account).to eq(merchant_account)
        expect(purchase.fee_cents).to eq(150) # 100 (10pc gumroad fee) + 50c
      end
    end

    context "charge on gumroad paypal account via braintree" do
      it "uses flat fee if applicable to the creator otherwise uses tier fee" do
        purchase = create(:purchase, link: @product, purchase_state: "in_progress", chargeable: create(:paypal_chargeable))
        purchase.process!

        expect(purchase.send(:flat_fee_applicable?)).to be true
        expect(purchase.charge_processor_id).to eq(BraintreeChargeProcessor.charge_processor_id)
        expect(purchase.fee_cents).to eq(209) # 100 (10pc gumroad fee) + 50c + 29 (2.9 pc paypal fee) + 30 (30c fixed paypal fee)
      end
    end

    it "charges discover fee of 30%" do
      @product.update!(discover_fee_per_thousand: 500)
      create(:user_compliance_info, user: @creator)

      stripe_purchase = create(:purchase, link: @product, purchase_state: "in_progress", was_product_recommended: true, chargeable: create(:chargeable))
      stripe_purchase.process!
      expect(stripe_purchase.reload.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
      expect(stripe_purchase.send(:flat_fee_applicable?)).to be true
      expect(stripe_purchase.fee_cents).to eq(300) # flat 30% discover fee

      braintree_purchase = create(:purchase, link: @product, purchase_state: "in_progress", was_product_recommended: true, chargeable: create(:paypal_chargeable))
      braintree_purchase.process!
      expect(braintree_purchase.reload.charge_processor_id).to eq(BraintreeChargeProcessor.charge_processor_id)
      expect(braintree_purchase.send(:flat_fee_applicable?)).to be true
      expect(braintree_purchase.fee_cents).to eq(300) # flat 30% discover fee

      Feature.activate_user(:merchant_migration, @creator)
      stripe_connect_account = create(:merchant_account_stripe_connect, user: @creator)
      stripe_connect_purchase = create(:purchase, link: @product, purchase_state: "in_progress", was_product_recommended: true, chargeable: create(:chargeable, product_permalink: @product.unique_permalink))
      stripe_connect_purchase.process!
      expect(stripe_connect_purchase.reload.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
      expect(stripe_connect_purchase.send(:flat_fee_applicable?)).to be true
      expect(stripe_connect_purchase.merchant_account).to eq(stripe_connect_account)
      expect(stripe_connect_purchase.fee_cents).to eq(300) # flat 30% discover fee
      Feature.deactivate_user(:merchant_migration, @creator)

      paypal_connect_account = create(:merchant_account_paypal, user: @creator, charge_processor_merchant_id: "CJS32DZ7NDN5L", country: "GB", currency: "gbp")
      paypal_connect_purchase = create(:purchase, link: @product, purchase_state: "in_progress", was_product_recommended: true, chargeable: create(:native_paypal_chargeable))
      paypal_connect_purchase.process!
      expect(paypal_connect_purchase.reload.charge_processor_id).to eq(PaypalChargeProcessor.charge_processor_id)
      expect(paypal_connect_purchase.send(:flat_fee_applicable?)).to be true
      expect(paypal_connect_purchase.merchant_account).to eq(paypal_connect_account)
      expect(paypal_connect_purchase.fee_cents).to eq(300) # flat 30% discover fee
    end

    shared_examples_for "charges no Gumroad fee on new sales" do
      it "does not charge 10% Gumroad fee for regular product sale" do
        purchase = create(:purchase, link: create(:product, user: seller), price_cents: 10_00)

        expect(purchase.seller.waive_gumroad_fee_on_new_sales?).to be true
        expect(purchase.fee_cents).to eq 109 # 2.9% + 30c cc fee
      end

      it "does not charge 10% Gumroad fee for new membership product sale" do
        purchase = create(:membership_purchase, link: create(:membership_product, user: seller), price_cents: 10_00)

        expect(purchase.seller.waive_gumroad_fee_on_new_sales?).to be true
        expect(purchase.fee_cents).to eq 109 # 2.9% + 30c cc fee
      end

      it "does not charge 10% Gumroad fee for recommended regular product sale" do
        purchase = create(:purchase, link: create(:product, user: seller), price_cents: 10_00,
                                     was_product_recommended: true,
                                     recommended_by: RecommendationType::GUMROAD_SEARCH_RECOMMENDATION)

        expect(purchase.seller.waive_gumroad_fee_on_new_sales?).to be true
        expect(purchase.was_product_recommended?).to be(true)
        expect(purchase.fee_cents).to eq 200 # 30% discover fee - 10% Gumroad fee
      end

      it "does not charge 10% Gumroad fee for recommended new membership product sale" do
        purchase = create(:membership_purchase, link: create(:membership_product, user: seller), price_cents: 10_00,
                                                was_product_recommended: true,
                                                recommended_by: RecommendationType::GUMROAD_SEARCH_RECOMMENDATION)

        expect(purchase.seller.waive_gumroad_fee_on_new_sales?).to be true
        expect(purchase.fee_cents).to eq 200 # 30% discover fee - 10% Gumroad fee
      end

      it "charges the boost fee minus the 10% Gumroad fee for recommended new membership product sale" do
        purchase = create(:membership_purchase,
                          link: create(:membership_product, user: seller, discover_fee_per_thousand: 400),
                          price_cents: 10_00,
                          was_product_recommended: true,
                          recommended_by: RecommendationType::GUMROAD_SEARCH_RECOMMENDATION)

        expect(purchase.seller.waive_gumroad_fee_on_new_sales?).to be true
        expect(purchase.was_product_recommended?).to be(true)
        expect(purchase.was_discover_fee_charged?).to be(true)
        expect(purchase.fee_cents).to eq 200 # 30% discover fee - 10% gumroad fee
      end

      it "charges 10% Gumroad fee for recurring charge on existing membership" do
        membership_sale = create(:membership_purchase, link: create(:membership_product, user: seller),
                                                       created_at: 1.week.ago, price_cents: 10_00)
        recurring_charge = create(:recurring_membership_purchase, link: membership_sale.link,
                                                                  subscription: membership_sale.subscription, price_cents: 10_00)

        expect(recurring_charge.seller.waive_gumroad_fee_on_new_sales?).to be true
        expect(recurring_charge.fee_cents).to eq 2_09 # 10% + 50c gumroad fee + 2.9% cc fee + 30c fixed cc fee
      end

      it "charges the boost fee including 10% Gumroad fee for recurring charge on recommended membership sale" do
        membership_sale = create(:membership_purchase,
                                 link: create(:membership_product, user: seller, discover_fee_per_thousand: 400),
                                 created_at: 1.week.ago,
                                 price_cents: 10_00,
                                 was_product_recommended: true,
                                 recommended_by: RecommendationType::GUMROAD_SEARCH_RECOMMENDATION)
        membership_sale.handle_recommended_purchase
        allow_any_instance_of(Subscription).to receive(:mor_fee_applicable?).and_return(false)

        recurring_charge = create(:recurring_membership_purchase,
                                  link: membership_sale.link,
                                  subscription: membership_sale.subscription,
                                  price_cents: 10_00,
                                  was_product_recommended: true,
                                  recommended_by: RecommendationType::GUMROAD_SEARCH_RECOMMENDATION)

        expect(recurring_charge.seller.waive_gumroad_fee_on_new_sales?).to be true
        expect(recurring_charge.was_product_recommended?).to be(true)
        expect(recurring_charge.was_discover_fee_charged?).to be(true)
        expect(recurring_charge.fee_cents).to eq 459 # 30% (boost fee) + 12.9% + 30c cc fee
      end

      it "charges 10% Gumroad fee for charge on existing preorder" do
        product = create(:product, user: seller, price_cents: 10_00, is_in_preorder_state: true)
        preorder_product = create(:preorder_link, link: product)
        authorization_purchase = build(:purchase, link: product, chargeable: create(:chargeable),
                                                  purchase_state: "in_progress", is_preorder_authorization: true)
        preorder = preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        product.update!(is_in_preorder_state: false)
        preorder_charge = preorder.charge!

        expect(preorder_charge.seller.waive_gumroad_fee_on_new_sales?).to be true
        expect(preorder_charge.fee_cents).to eq 2_09 # 10% gumroad flat fee + 50c + 2.9% cc fee + 30c fixed cc fee
      end
    end

    describe "on Gumroad day" do
      let!(:seller) { create(:named_seller) }

      before do
        $redis.set(RedisKey.gumroad_day_date, Time.now.in_time_zone(seller.timezone).to_date.to_s)
      end

      it_behaves_like "charges no Gumroad fee on new sales"
    end

    describe "with waive_gumroad_fee_on_new_sales feature flag set" do
      let!(:seller) { create(:named_seller) }

      before do
        Feature.activate_user(:waive_gumroad_fee_on_new_sales, seller)
      end

      it_behaves_like "charges no Gumroad fee on new sales"
    end
  end

  describe "purchase requires either purchaser or email" do
    it "works with a purchaser" do
      user = create(:user)
      purchase = build(:purchase, purchaser: user)
      expect(purchase).to be_valid
    end

    it "works with an email" do
      purchase = build(:purchase, email: "test@example.com")
      expect(purchase).to be_valid
    end

    it "is not valid without either" do
      purchase = build(:purchase, email: nil)
      expect(purchase).to_not be_valid
    end
  end

  describe "create_url_redirect!" do
    before do
      @purchase = create(:purchase)
      @purchase.perceived_price_cents = 100
      @purchase.save_card = false
      @purchase.ip_address = ip_address
      @purchase.chargeable = build(:chargeable)
      @purchase.process!
    end

    it "doesn't create it multiple times, even if called a bunch" do
      expect do
        @purchase.create_url_redirect!
        @purchase.create_url_redirect!
        @purchase.create_url_redirect!
      end.to change(UrlRedirect, :count).by(1)
    end

    describe "commission completion purchase" do
      let(:purchase) { create(:purchase, is_commission_completion_purchase: true) }

      it "does not create a url redirect" do
        purchase.create_url_redirect!
        expect(purchase.url_redirect).to be_nil
      end
    end

    describe "subscriptions" do
      before do
        @user = create(:user)
        @product = create(:membership_product, user: @user, price_cents: 600, subscription_duration: :monthly, should_include_last_post: true)
        @subscription = create(:subscription, link: @product)
        @purchase = create(:purchase, link: @product, seller: @user, purchase_state: "in_progress", is_original_subscription_purchase: true)
        @purchase.perceived_price_cents = 100
        @purchase.ip_address = ip_address
        @purchase.chargeable = build(:chargeable)
        @purchase.process!
      end

      describe "has past installments" do
        before do
          @post = create(:installment, link: @product, published_at: 1.hour.ago)
          @post.product_files << create(:product_file)
          @workflow = create(:workflow, seller: @user, link: @product, published_at: Time.current)
          @workflow_post = create(:installment, link: @product, workflow: @workflow, published_at: Time.current)
          create(:installment_rule, installment: @workflow_post, delayed_delivery_time: 3.days)
        end

        it "sends the last installment as an email to the new subscriber" do
          @subscription.purchases << @purchase
          @purchase.update_balance_and_mark_successful!

          expect(SendLastPostJob).to have_enqueued_sidekiq_job.with(@purchase.id)
        end

        it "does not send the last installment to the subscriber on recurring charges" do
          create(:installment, link: @product, published_at: Time.current)

          @subscription.purchases << @purchase
          @purchase.update_balance_and_mark_successful!

          SendLastPostJob.jobs.clear

          recurring_purchase = create(:purchase, seller: @user, purchase_state: "in_progress", subscription: @subscription, link: @product)
          recurring_purchase.update_balance_and_mark_successful!

          expect(SendLastPostJob.jobs).to be_empty
        end

        describe "subscription should not send last update" do
          before do
            @product.update_attribute(:should_include_last_post, false)
          end

          it "does not send the last installment to the new subscriber" do
            @subscription.purchases << @purchase
            @purchase.update_balance_and_mark_successful!

            expect(SendLastPostJob.jobs).to be_empty
          end
        end
      end
    end

    describe "non-webhook product" do
      before do
        @product = create(:product)
      end

      it "creates a url_redirect" do
        purchase = create(:purchase, link: @product)
        expect { purchase.create_url_redirect! }.to change(UrlRedirect, :count).by(1)
      end
    end
  end

  describe "financial_transaction_valid?" do
    it "has charge processor details if amount not 0" do
      p = create(:purchase, email: "email@email.email", purchase_state: "in_progress")

      p.stripe_fingerprint = "some-fingerprint"
      p.stripe_transaction_id = nil
      p.charge_processor_id = nil
      expect(p.mark_successful).to be(false)

      p.stripe_fingerprint = nil
      p.stripe_transaction_id = "some-value"
      p.charge_processor_id = nil
      expect(p.mark_successful).to be(false)

      p.stripe_fingerprint = nil
      p.stripe_transaction_id = nil
      p.charge_processor_id = "some-processor"
      expect(p.mark_successful).to be(false)

      p.stripe_fingerprint = "some-fingerprint"
      p.stripe_transaction_id = "some-value"
      p.charge_processor_id = nil
      expect(p.mark_successful).to be(false)

      p.stripe_fingerprint = "some-fingerprint"
      p.stripe_transaction_id = nil
      p.charge_processor_id = "some-processor"
      expect(p.mark_successful).to be(false)

      p.stripe_fingerprint = nil
      p.stripe_transaction_id = "some-value"
      p.charge_processor_id = "some-processor"
      expect(p.mark_successful).to be(false)

      p.stripe_transaction_id = nil
      p.stripe_fingerprint = nil
      p.charge_processor_id = nil
      expect(p.mark_successful).to be(false)

      p.stripe_fingerprint = "some-fingerprint"
      p.stripe_transaction_id = "some-value"
      p.charge_processor_id = "some-processor"
      expect(p.mark_successful).to be(true)
    end

    it "does not update with charge processor details if amount = 0" do
      link = create(:product, price_range: "$0+")
      p = create(:purchase, link:, seller: link.user, email: "email@email.email", purchase_state: "in_progress")
      p.price_cents = 0

      p.stripe_fingerprint = "some-fingerprint"
      p.stripe_transaction_id = nil
      p.charge_processor_id = nil
      expect(p.mark_successful).to be(false)

      p.stripe_fingerprint = nil
      p.stripe_transaction_id = "some-value"
      p.charge_processor_id = nil
      expect(p.mark_successful).to be(false)

      p.stripe_fingerprint = nil
      p.stripe_transaction_id = nil
      p.charge_processor_id = "some-processor"
      expect(p.mark_successful).to be(false)

      p.stripe_fingerprint = "some-fingerprint"
      p.stripe_transaction_id = "some-value"
      p.charge_processor_id = nil
      expect(p.mark_successful).to be(false)

      p.stripe_fingerprint = "some-fingerprint"
      p.stripe_transaction_id = nil
      p.charge_processor_id = "some-processor"
      expect(p.mark_successful).to be(false)

      p.stripe_fingerprint = nil
      p.stripe_transaction_id = "some-value"
      p.charge_processor_id = "some-processor"
      expect(p.mark_successful).to be(false)

      p.stripe_fingerprint = "some-fingerprint"
      p.stripe_transaction_id = "some-value"
      p.charge_processor_id = "some-processor"
      expect(p.mark_successful).to be(false)

      p.stripe_transaction_id = nil
      p.stripe_fingerprint = nil
      p.charge_processor_id = nil
      p.merchant_account = nil
      expect(p.mark_successful).to be(true)
    end
  end

  describe "merchant account" do
    let(:user) { create(:user) }
    let(:physical) { false }
    let(:link) { create(:product, user:, is_physical: physical, require_shipping: physical, shipping_destinations: [(create(:shipping_destination) if physical)].compact) }
    let(:chargeable) { build(:chargeable) }
    let(:purchase) do
      create(:purchase, seller: user, link:, price_cents: link.price_cents, fee_cents: 30, purchase_state: "in_progress", merchant_account: nil, chargeable:,
                        full_name: "Edgar Gumstein", street_address: "123 Gum Road", state: "CA", city: "San Francisco", zip_code: "94017", country: "United States")
    end

    describe "when the creator does not have their own merchant account" do
      it "is charged using a Gumroad merchant account for suppliers" do
        purchase.process!
        expect(purchase.errors).to be_empty
        expect(purchase.merchant_account).to eq(MerchantAccount.gumroad(purchase.charge_processor_id))
      end
    end

    describe "when the creator has their own merchant account" do
      let(:merchant_account) { create(:merchant_account_stripe, user:) }

      before do
        merchant_account
        user.reload
      end

      describe "when the link is digital" do
        it "is charged using the creators merchant account" do
          purchase.process!
          expect(purchase.errors).to be_empty
          expect(purchase.merchant_account).to eq(merchant_account)
        end
      end

      describe "when the link is physical" do
        let(:physical) { true }

        it "is charged using the creators merchant account" do
          purchase.process!
          expect(purchase.errors).to be_empty
          expect(purchase.merchant_account).to eq(user.merchant_account(purchase.charge_processor_id))
        end
      end

      describe "when the purchase has sales tax that gumroad is collecting and will pay as the merchant" do
        let(:purchase) do
          create(:purchase, seller: user, link:, price_cents: link.price_cents, fee_cents: 30, purchase_state: "in_progress", merchant_account: nil, chargeable:,
                            full_name: "Edgar Gumstein", street_address: "123 Gum Road", city: "London", zip_code: "94017", country: "United Kingdom", ip_country: "United Kingdom")
        end

        before do
          allow(chargeable).to receive(:country).and_return(Compliance::Countries::GBR.alpha2)
          create(:zip_tax_rate, zip_code: nil, state: nil, country: Compliance::Countries::GBR.alpha2, combined_rate: 1.0, is_seller_responsible: false)
        end

        it "is charged using a Gumroad merchant account for suppliers" do
          purchase.process!
          expect(purchase.errors).to be_empty
          expect(purchase.merchant_account).to eq(merchant_account)
        end
      end
    end
  end

  describe "not_double_charged" do
    before do
      @product = create(:product)
      @ip_address = generate(:ip)
    end

    it "allows double charges with bundle product purchases" do
      create(:purchase, link: @product, seller: @product.user, email: "bob@gumroad.com", ip_address: @ip_address, created_at: Time.current)
      purchase2 = build(:purchase, link: @product, email: "bob@gumroad.com", ip_address: @ip_address, created_at: Time.current, is_bundle_product_purchase: true)
      expect(purchase2).to be_valid
    end

    it "disallows double-charges to the same email and IP address" do
      purchase1 = create(:purchase, link: @product, seller: @product.user, email: "bob@gumroad.com", ip_address: @ip_address, created_at: Time.current)
      purchase2 = build(:purchase, link: @product, email: "bob@gumroad.com", ip_address: @ip_address, created_at: Time.current)
      expect(purchase1.id).to_not eq purchase2.id
      expect(purchase2).to_not be_valid
    end

    it "allows double-charges to different IP addresses" do
      create(:purchase, link: @product, seller: @product.user, email: "bob@gumroad.com", ip_address: @ip_address, created_at: Time.current)
      purchase2 = build(:purchase, link: @product, email: "bob2@gumroad.com", created_at: Time.current)
      expect(purchase2).to be_valid
    end

    it "disallows double-charges if the first purchase is in progress" do
      purchase1 = create(:purchase, link: @product, seller: @product.user, email: "bob@gumroad.com", ip_address: @ip_address, created_at: Time.current, purchase_state: "in_progress")
      purchase2 = build(:purchase, link: @product, email: "bob@gumroad.com", ip_address: @ip_address, created_at: Time.current)
      expect(purchase1.id).to_not eq purchase2.id
      expect(purchase2).to_not be_valid
    end

    it "allows double-charges after 5 min" do
      create(:purchase, link: @product, seller: @product.user, email: "bob@gumroad.com", ip_address: @ip_address, created_at: 6.minutes.ago)
      purchase2 = build(:purchase, link: @product, email: "bob@gumroad.com", ip_address: @ip_address, created_at: Time.current)
      expect(purchase2).to be_valid
    end

    it "allows double-charge if purchase is marked as 'automatic'" do
      create(:purchase, link: @product, seller: @product.user, ip_address: @ip_address, email: "tweeter@gumroad.com", created_at: Time.current)
      purchase2 = build(:purchase, link: @product, ip_address: @ip_address, email: "tweeter@gumroad.com", created_at: Time.current)
      purchase2.is_automatic_charge = true
      expect(purchase2).to be_valid
    end

    it "allows double-charge if purchase is from the profile page and of a quantity-enabled product" do
      product = create(:physical_product, quantity_enabled: true)
      create(:physical_purchase, link: product, seller: product.user, ip_address: @ip_address, email: "bob@gumroad.com", created_at: Time.current)
      purchase2 = build(:physical_purchase, link: product, ip_address: @ip_address, email: "bob@gumroad.com", created_at: Time.current)
      purchase2.is_multi_buy = true
      purchase2.variant_attributes << product.skus.is_default_sku.first
      expect(purchase2).to be_valid
    end

    context "when gifting" do
      before do
        travel_to(Time.current)
      end

      let(:giftee_email) { generate(:email) }
      let(:gift) { create(:gift, giftee_email:) }
      let(:product) { create(:product) }
      let(:gifter_email) { generate(:email) }

      context "as first product purchase" do
        it "allows the gift-purchase" do
          purchase_given = build(:purchase, link: product, gift_given: gift, is_gift_sender_purchase: true, ip_address: @ip_address, email: gifter_email)
          purchase_given.send(:not_double_charged)
          expect(purchase_given).to be_valid

          purchase_received = build(:purchase, link: product, gift_received: gift, is_gift_receiver_purchase: true, ip_address: @ip_address, email: giftee_email)
          purchase_received.send(:not_double_charged)
          expect(purchase_received).to be_valid
        end
      end

      context "after purchasing it as a non-gift" do
        before do
          create(:purchase, link: product)
        end

        it "allows the gift-purchase" do
          purchase_given = build(:purchase, link: product, gift_given: gift, purchaser: user, is_gift_sender_purchase: true, ip_address: @ip_address, email: gifter_email)
          purchase_given.send(:not_double_charged)
          expect(purchase_given).to be_valid

          purchase_received = build(:purchase, link: product, gift_received: gift, is_gift_receiver_purchase: true, ip_address: @ip_address, email: giftee_email)
          purchase_received.send(:not_double_charged)
          expect(purchase_received).to be_valid
        end
      end

      context "after gifting to someone else" do
        before do
          @original_purchase = create(:purchase, link: product, gift_given: gift, purchaser: user, is_gift_sender_purchase: true, ip_address: @ip_address, email: user.email)
        end

        it "allows the gift-purchase" do
          second_giftee_email = generate(:email)
          second_gift = create(:gift, giftee_email: second_giftee_email)

          purchase_given = build(:purchase, link: product, gift_given: second_gift, purchaser: user, is_gift_sender_purchase: true, ip_address: @ip_address, email: user.email)
          purchase_given.send(:not_double_charged)
          expect(purchase_given).to be_valid

          purchase_received = build(:purchase, link: product, gift_received: second_gift, is_gift_receiver_purchase: true, ip_address: @ip_address, email: second_giftee_email)
          purchase_received.send(:not_double_charged)
          expect(purchase_received).to be_valid
        end

        it "allows purchase as a non-gift to original purchaser" do
          purchase = build(:purchase, link: product, purchaser: user, email: user.email, ip_address: @ip_address)
          purchase.send(:not_double_charged)
          expect(purchase).to be_valid
        end
      end

      context "when gifting a subscription" do
        let!(:original_purchase) { create(:membership_purchase, link: product, gift_given: gift, purchaser: user, is_gift_sender_purchase: true, email: user.email, ip_address: @ip_address, subscription: create(:subscription)) }

        it "disallows double-charges to the same email and IP address" do
          purchase = build(:membership_purchase, link: product, email: gift.giftee_email, ip_address: @ip_address, created_at: Time.current)
          expect(original_purchase.id).to_not eq purchase.id
          expect(purchase).to_not be_valid
          expect(purchase.errors[:base]).to eq ["You have already paid for this product. It has been emailed to you."]
        end

        it "allows the recurring charge" do
          purchase = build(:recurring_membership_purchase, link: original_purchase.link, subscription: original_purchase.subscription, purchaser: user, email: giftee_email)
          expect(purchase).to be_valid
        end
      end
    end

    context "purchasing physical products" do
      let(:product) { create(:physical_product) }

      it "prohibits double-charges within 10 seconds" do
        create(:physical_purchase, link: product, seller: product.user, ip_address: @ip_address, email: "bob@gumroad.com", variant_attributes: [product.skus.is_default_sku.first], created_at: 8.seconds.ago)
        purchase2 = build(:physical_purchase, link: product, ip_address: @ip_address, email: "bob@gumroad.com", variant_attributes: [product.skus.is_default_sku.first])
        expect(purchase2).to_not be_valid
        expect(purchase2.errors[:base]).to eq ["You have already paid for this product. It has been emailed to you."]
      end

      it "allows double-charges after 10 seconds" do
        create(:physical_purchase, link: product, seller: product.user, ip_address: @ip_address, email: "bob@gumroad.com", variant_attributes: [product.skus.is_default_sku.first], created_at: 11.seconds.ago)
        purchase2 = build(:physical_purchase, link: product, ip_address: @ip_address, email: "bob@gumroad.com", variant_attributes: [product.skus.is_default_sku.first])
        expect(purchase2).to be_valid
      end
    end

    context "purchasing licensed products" do
      let(:product) { create(:product, is_licensed: true) }

      it "prohibits double-charges within 10 seconds" do
        create(:purchase, link: product, seller: product.user, ip_address: @ip_address, email: "bob@gumroad.com", created_at: 8.seconds.ago)
        purchase2 = build(:purchase, link: product, ip_address: @ip_address, email: "bob@gumroad.com")
        expect(purchase2).to_not be_valid
        expect(purchase2.errors[:base]).to eq ["You have already paid for this product. It has been emailed to you."]
      end

      it "allows double-charges after 10 seconds" do
        create(:purchase, link: product, seller: product.user, ip_address: @ip_address, email: "bob@gumroad.com", created_at: 11.seconds.ago)
        purchase2 = build(:purchase, link: product, ip_address: @ip_address, email: "bob@gumroad.com")
        expect(purchase2).to be_valid
      end
    end

    context "when upgrading a subscription" do
      it "prohibits double-charges within 10 seconds" do
        purchase = create(:membership_purchase, ip_address: @ip_address, email: "bob@gumroad.com", created_at: 5.seconds.ago)
        purchase2 = build(:membership_purchase, ip_address: @ip_address, email: "bob@gumroad.com", subscription: purchase.subscription, link: purchase.link, is_original_subscription_purchase: false, is_upgrade_purchase: true)
        expect(purchase2).to_not be_valid
        expect(purchase2.errors[:base]).to eq ["You have already paid for this product. It has been emailed to you."]
      end

      it "allows double-charges after 10 seconds" do
        purchase = create(:membership_purchase, ip_address: @ip_address, email: "bob@gumroad.com", created_at: 11.seconds.ago)
        purchase2 = build(:membership_purchase, ip_address: @ip_address, email: "bob@gumroad.com", subscription: purchase.subscription, link: purchase.link, is_original_subscription_purchase: false, is_upgrade_purchase: true)
        expect(purchase2).to be_valid
      end
    end
  end

  describe "purchaser_email_or_email" do
    it "provides email if no purchaser" do
      purchase = create(:purchase, email: "bob@example.com", purchaser: nil)
      expect(purchase.purchaser_email_or_email).to eq "bob@example.com"
    end

    it "provides purchaser email if it exists" do
      buyer = create(:user, email: "margaret@example.com")
      purchase = create(:purchase, email: "email@email.email", purchaser: buyer)
      expect(purchase.purchaser_email_or_email).to eq "margaret@example.com"
    end

    it "provides email if purchase email blank" do
      buyer = create(:user, email: "", provider: :twitter)
      purchase = create(:purchase, purchaser: buyer)
      expect(purchase.purchaser_email_or_email).to be_present
    end

    it "provides email if both are present" do
      buyer = create(:user, email: "margaret@example.com")
      purchase = create(:purchase, email: "bob@example.com", purchaser: buyer)
      expect(purchase.purchaser_email_or_email).to eq "margaret@example.com"
    end
  end

  describe "additional information passed to charge processor" do
    describe "reference" do
      let(:purchase) { create(:purchase_with_balance, chargeable: build(:chargeable)) }

      it "is sent with the default if the statement description isn't customized" do
        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).with(
          anything, anything, anything, anything, purchase.external_id, anything, anything
        ).and_call_original
        purchase.process!
      end
    end

    describe "soft descriptor with creator" do
      before do
        @user = create(:named_user)
        @product = create(:product, user: @user)
        @chargeable = build(:chargeable)
        @purchase = create(:purchase, chargeable: @chargeable, state: :in_progress, link: @product)
      end

      it "is sent with creator name" do
        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).with(anything, @chargeable, anything, anything, anything, anything,
                                                                                   hash_including(statement_description: @user.name_or_username, transfer_group: @purchase.id)).and_call_original
        @purchase.process!
      end
    end
  end

  describe "total_transaction_amount_for_gumroad_cents" do
    let(:seller) { create(:named_seller) }
    let(:link) { create(:product, user: seller, price_cents: 4_00) }
    let(:chargeable) { build(:chargeable) }
    let(:purchase) do
      purchase = create(
        :purchase_with_balance,
        chargeable:,
        state: :in_progress,
        seller:,
        link:
      )
      allow(purchase).to receive(:gumroad_tax_cents).and_return(50)
      allow(purchase).to receive(:total_transaction_cents).and_return(4_50)
      purchase
    end

    it "is the sum of the fee cents and tax that gumroad collected" do
      expect(purchase.total_transaction_amount_for_gumroad_cents).to eq(182) # 132c fee (10% + 50c + 2.9% + 30c) + 50c gumroad tax
    end

    describe "use when charging" do
      it "is sent to the charge processor" do
        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).with(
          anything,
          chargeable,
          purchase.total_transaction_cents,
          purchase.total_transaction_amount_for_gumroad_cents,
          anything,
          anything,
          anything
        ).and_call_original
        purchase.process!
      end
    end
  end

  describe "#formatted_total_price" do
    it "returns the formatted price" do
      purchase = create(:purchase, price_cents: 500)
      expect(purchase.formatted_total_price).to eq "$5"
    end

    it "converts to the purchase currency" do
      purchase = create(:purchase, price_cents: 500, displayed_price_currency_type: Currency::JPY, link: create(:product, price_cents: 100, price_currency_type: Currency::USD))
      allow(purchase).to receive(:get_rate).and_return(150)

      expect(purchase.formatted_total_price).to eq "¥750"
    end
  end

  describe "calculate_price_range_cents" do
    # TODO: This method is mostly tested in magic_save!, but it should really be
    # tested on its own.

    before do
      usd_link = create(:product)
      @p_usd = create(:purchase, link: usd_link, seller: usd_link.user)
      yen_link = create(:product, price_currency_type: "jpy")
      @p_yen = create(:purchase, link: yen_link, seller: yen_link.user)
    end

    it "handles euro-style entries" do
      @p_usd.price_range = "999,99"
      expect(@p_usd.send(:calculate_price_range_cents)).to eq 99_999
      @p_usd.price_range = "999.99"
      expect(@p_usd.send(:calculate_price_range_cents)).to eq 99_999
      @p_usd.price_range = "1.999,99"
      expect(@p_usd.send(:calculate_price_range_cents)).to eq 199_999
      @p_usd.price_range = "1,999.99"
      expect(@p_usd.send(:calculate_price_range_cents)).to eq 199_999
      @p_usd.price_range = "1,999"
      expect(@p_usd.send(:calculate_price_range_cents)).to eq 199_900
    end

    it "does nothing for single unit currencies" do
      @p_yen.price_range = "9,99"
      expect(@p_yen.send(:calculate_price_range_cents)).to eq 999
    end
  end

  describe "check purchase heuristics after purchase" do
    it "queue up job to assess risk of purchase after purchase" do
      user = create(:user)
      product = create(:product, user:)
      purchase = create(:purchase, link: product, card_country: "US", ip_address: "110.227.155.107")
      purchase.send(:check_purchase_heuristics)

      expect(CheckPurchaseHeuristicsWorker).to have_enqueued_sidekiq_job(purchase.id)
    end
  end

  describe "#purchase_info" do
    let(:link) { create(:product_with_pdf_file) }
    let(:purchase) { create(:purchase, link:) }
    let(:zip_tax_rate) { create(:zip_tax_rate, country: "us", combined_rate: 0.2) }
    let(:subscription) { create(:subscription) }
    let(:url_redirect) { create(:url_redirect) }
    let!(:review) { create(:product_review, purchase:, rating: 4, message: "This is my review!") }

    before :each do
      allow(ObfuscateIds).to receive(:encrypt).and_return(1)
      allow(purchase).to receive(:can_contact).and_return(false)
      allow(purchase).to receive(:email).and_return("hi@gumroad.com")
      allow(purchase).to receive(:formatted_display_price).and_return(100)
    end

    it "returns correct purchase info" do
      allow(purchase).to receive(:url_redirect).and_return(url_redirect)
      url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3?AWSAccessKeyId=AKIAJU7Y4N2WOSYMBKBA&Expires=1375117394&"
      url += "Signature=NVzpNIuQlqCyGrx%2BiySqSXBhis4%3D&response-content-disposition=attachment"
      allow(url_redirect).to receive(:redirect_or_s3_location).and_return(url)

      expect(Purchase.purchase_info(url_redirect, link, purchase)).to eq(should_show_receipt: true,
                                                                         show_view_content_button_on_product_page: true,
                                                                         is_recurring_billing: false,
                                                                         is_physical: false,
                                                                         has_files: true,
                                                                         is_gift_receiver_purchase: false,
                                                                         gift_receiver_text: " bought this for you.",
                                                                         gift_sender_text: "You bought this for .",
                                                                         is_gift_sender_purchase: false,
                                                                         content_url: url_redirect.download_page_url,
                                                                         redirect_token: url_redirect.token,
                                                                         price: 100,
                                                                         product_id: link.external_id,
                                                                         has_third_party_analytics: false,
                                                                         id: 1,
                                                                         created_at: purchase.created_at,
                                                                         email: "hi@gumroad.com",
                                                                         email_digest: purchase.email_digest,
                                                                         full_name: nil,
                                                                         is_following: false,
                                                                         product_rating: 4,
                                                                         review: ProductReviewPresenter.new(purchase.product_review).review_form_props,
                                                                         view_content_button_text: view_content_button_text(link),
                                                                         account_by_this_email_exists: false,
                                                                         display_product_reviews: true,
                                                                         currency_type: "usd",
                                                                         non_formatted_price: 100,
                                                                         non_formatted_seller_tax_amount: "0",
                                                                         has_sales_tax_to_show: false,
                                                                         was_tax_excluded_from_price: false,
                                                                         sales_tax_amount: "$0",
                                                                         sales_tax_label: nil,
                                                                         quantity: 1,
                                                                         show_quantity: false,
                                                                         has_sales_tax_or_shipping_to_show: false,
                                                                         has_shipping_to_show: false,
                                                                         shipping_amount: "$0",
                                                                         total_price_including_tax_and_shipping: "$1",
                                                                         subscription_has_lapsed: false,
                                                                         url_redirect_external_id: url_redirect.external_id,
                                                                         domain: DOMAIN,
                                                                         protocol: PROTOCOL,
                                                                         native_type: Link::NATIVE_TYPE_DIGITAL,
                                                                         enabled_integrations: { "circle" => false, "discord" => false, "zoom" => false, "google_calendar" => false })
    end

    it "returns purchase info with account_by_this_email_exists set to true if purchaser_id is set for the purchase" do
      purchase.purchaser = create(:user, email: purchase.email)
      purchase.save!

      expect(Purchase.purchase_info(url_redirect, link, purchase)[:account_by_this_email_exists]).to eq(true)
    end

    it "returns nil for content_url and content_token if url_redirect is not present" do
      allow(link).to receive(:url_redirect).and_return(nil)
      expect(Purchase.purchase_info(nil, link, purchase)[:content_url]).to eq(nil)
      expect(Purchase.purchase_info(nil, link, purchase)[:redirect_token]).to eq(nil)
    end

    it "shows test purchase notice if purchase is a test" do
      allow(purchase).to receive(:is_test_purchase?).and_return(true)
      expect(Purchase.purchase_info(url_redirect, link, purchase)[:test_purchase_notice]).to eq("This was a test purchase — you have not been charged (you are seeing this message because you are logged in as the creator).")
    end

    it "returns sales tax amount and indicates it has sales tax to show if exclusive and present" do
      purchase.tax_cents = 25
      purchase.price_cents = 125
      purchase.total_transaction_cents = 125
      purchase.displayed_price_cents = 100
      purchase.was_purchase_taxable = true
      purchase.was_tax_excluded_from_price = true
      purchase.zip_tax_rate = zip_tax_rate

      expect(Purchase.purchase_info(nil, link, purchase)[:has_sales_tax_to_show]).to eq(true)
      expect(Purchase.purchase_info(nil, link, purchase)[:sales_tax_amount]).to eq("$0.25")
      expect(Purchase.purchase_info(nil, link, purchase)[:sales_tax_label]).to eq("Sales tax")
      expect(Purchase.purchase_info(nil, link, purchase)[:total_price_including_tax_and_shipping]).to eq("$1.25")
      expect(Purchase.purchase_info(nil, link, purchase)[:was_tax_excluded_from_price]).to eq(true)
    end

    it "returns sales tax amount and indicates it has sales tax to show if inclusive and present" do
      purchase.tax_cents = 25
      purchase.price_cents = 100
      purchase.total_transaction_cents = 100
      purchase.displayed_price_cents = 100
      purchase.was_purchase_taxable = true
      purchase.was_tax_excluded_from_price = false
      purchase.zip_tax_rate = zip_tax_rate

      expect(Purchase.purchase_info(nil, link, purchase)[:has_sales_tax_to_show]).to eq(true)
      expect(Purchase.purchase_info(nil, link, purchase)[:sales_tax_amount]).to eq("$0.25")
      expect(Purchase.purchase_info(nil, link, purchase)[:sales_tax_label]).to eq("Sales tax (included)")
      expect(Purchase.purchase_info(nil, link, purchase)[:total_price_including_tax_and_shipping]).to eq("$1")
      expect(Purchase.purchase_info(nil, link, purchase)[:was_tax_excluded_from_price]).to eq(false)
    end

    it "returns quantity and show_quantity for physical product purchase" do
      link.update_attribute(:is_physical, true)
      purchase.update_attribute(:quantity, 5)

      expect(Purchase.purchase_info(nil, link, purchase)[:show_quantity]).to eq(true)
      expect(Purchase.purchase_info(nil, link, purchase)[:quantity]).to eq(5)
    end

    it "returns shipping and has_shipping_to_show for physical product purchase with shipping" do
      link.update_attribute(:is_physical, true)
      purchase.update_attribute(:shipping_cents, 10_00)

      expect(Purchase.purchase_info(nil, link, purchase)[:has_shipping_to_show]).to eq(true)
      expect(Purchase.purchase_info(nil, link, purchase)[:shipping_amount]).to eq("$10")
    end

    it "returns the tracking url for physical product purchase where order has been shipped with tracking" do
      link.update_attribute(:is_physical, true)
      shipment = create(:shipment, purchase:, tracking_url: "https://tools.usps.com/go/TrackConfirmAction?qtc_tLabels1=1234567890")
      shipment.mark_shipped

      expect(Purchase.purchase_info(nil, link, purchase)[:shipped]).to eq(true)
      expect(Purchase.purchase_info(nil, link, purchase)[:tracking_url]).to eq(shipment.tracking_url)
    end

    it "returns membership-specific information for a purchase" do
      purchase = create(:membership_purchase)
      product = purchase.link
      purchase.subscription.update!(cancelled_at: 1.minute.ago)
      purchase.variant_attributes.first.update!(name: "Base tier")

      expect(Purchase.purchase_info(nil, product, purchase)[:subscription_has_lapsed]).to eq true
      expect(Purchase.purchase_info(nil, product, purchase)[:membership][:tier_name]).to eq("Base tier")
      expect(Purchase.purchase_info(nil, product, purchase)[:membership][:tier_description]).to eq(nil)
      expect(Purchase.purchase_info(nil, product, purchase)[:membership][:manage_url]).to eq(Rails.application.routes.url_helpers.manage_subscription_url(purchase.subscription.external_id, host: "#{PROTOCOL}://#{DOMAIN}"))
    end

    it "returns license_key if it exists" do
      link.is_licensed = true
      license = create(:license, purchase:)
      expect(Purchase.purchase_info(nil, link, purchase)[:license_key]).to eq(license.serial)
    end

    it "returns should_show_receipt as true if purchase is a received gift" do
      purchase = create(:purchase, :gift_receiver)
      expect(Purchase.purchase_info(nil, link, purchase)[:should_show_receipt]).to eq(true)
    end

    describe "bundle purchase" do
      let(:purchase) { create(:purchase, link: create(:product, :bundle)) }

      before do
        purchase.create_artifacts_and_send_receipt!
      end

      it "includes bundle products" do
        expect(Purchase.purchase_info(nil, purchase.link, purchase)[:bundle_products]).to eq(
          [
            {
              id: purchase.product_purchases.first.link.external_id,
              content_url: purchase.product_purchases.first.url_redirect.download_page_url,
            },
            {
              id: purchase.product_purchases.second.link.external_id,
              content_url: purchase.product_purchases.second.url_redirect.download_page_url,
            }
          ]
        )
      end
    end
  end

  describe "#purchase_response" do
    let(:user) { create(:user, username: "admin2") }
    let(:link) { create(:product, user:, unique_permalink: "unique", custom_permalink: "custom") }
    let(:preorder_link) { create(:preorder_link) }
    let(:purchase) { create(:purchase, link:, full_name: "Edgar Gumstein", street_address: "123 Gum Road", country: "United States", zip_code: "94107", state: "CA", city: "San Francisco") }
    let(:url_redirect) { create(:url_redirect) }

    before :each do
      allow(Purchase).to receive(:purchase_info).and_return(purchase_info: {})
    end

    it "returns unique permalink even if product has a custom permalink" do
      expect(Purchase.purchase_response(url_redirect, link, purchase)[:permalink]).to eq("unique")
    end

    it "returns purchase response with purchase info and payload_for_ping_notification merged" do
      purchase_response = { purchase_info: {},
                            success: true,
                            remaining: link.remaining_for_sale_count,
                            permalink: "unique",
                            name: link.name,
                            variants: link.variant_list,
                            extra_purchase_notice: nil,
                            twitter_share_url: link.twitter_share_url,
                            twitter_share_text: link.social_share_text }
      ping_payload = purchase.payload_for_ping_notification(url_parameters: purchase.url_parameters,
                                                            resource_name: ResourceSubscription::SALE_RESOURCE_NAME)
      expect(Purchase.purchase_response(url_redirect, link, purchase)).to eq(purchase_response.reverse_merge(ping_payload))
    end

    it "returns emailed preorder notice if link is in preorder state" do
      allow(link).to receive(:is_in_preorder_state).and_return(true)
      allow(link).to receive(:preorder_link).and_return(preorder_link)
      allow(Purchase).to receive(:displayable_release_at_date_and_time).and_return("")
      expect(Purchase.purchase_response(url_redirect, link, purchase)[:extra_purchase_notice]).to eq "You'll get it on ."
    end

    it "returns emailed physical preorder notice if link is physical and in preorder state" do
      allow(link).to receive(:is_in_preorder_state).and_return(true)
      allow(link).to receive(:is_physical).and_return(true)
      allow(link).to receive(:preorder_link).and_return(preorder_link)
      allow(Purchase).to receive(:displayable_release_at_date_and_time).and_return("")
      expect(Purchase.purchase_response(url_redirect, link, purchase)[:extra_purchase_notice]).to eq "You'll be charged on , and shipment will occur soon after."
    end

    it "returns subscription notice if link is subscription" do
      allow(link).to receive(:is_recurring_billing).and_return(true)
      expect(Purchase.purchase_response(url_redirect, link, purchase)[:extra_purchase_notice])
        .to eq "You will receive an email when there's new content."
    end

    it "returns physcial subscription notice if link is a physcial subscription" do
      allow(link).to receive(:is_recurring_billing).and_return(true)
      allow(link).to receive(:is_physical).and_return(true)
      expect(Purchase.purchase_response(url_redirect, link, purchase)[:extra_purchase_notice])
        .to eq "You will also receive updates over email."
    end
  end

  describe "#notify_seller!" do
    context "purchase is a bundle product purchase" do
      let(:purchase) { create(:purchase, is_bundle_product_purchase: true) }

      it "doesn't notify the seller" do
        expect { purchase.notify_seller! }.to_not have_enqueued_mail(ContactingCreatorMailer, :notify)
      end
    end

    context "purchase is a commission completion purchase" do
      let(:purchase) { create(:purchase, is_commission_completion_purchase: true) }

      it "doesn't notify the seller" do
        expect { purchase.notify_seller! }.to_not have_enqueued_mail(ContactingCreatorMailer, :notify)
      end
    end
  end

  describe "#create_artifacts_and_send_receipt!" do
    context "purchase is a bundle purchase" do
      let(:seller) { create(:named_seller) }
      let(:purchaser) { create(:buyer_user) }
      let(:bundle) { create(:product, user: seller, is_bundle: true) }

      let(:product) { create(:product, user: seller, name: "Product", custom_fields: [create(:custom_field, name: "Key")]) }
      let!(:bundle_product) { create(:bundle_product, bundle:, product:) }

      let(:versioned_product) { create(:product_with_digital_versions, user: seller, name: "Versioned product") }
      let!(:versioned_bundle_product) { create(:bundle_product, bundle:, product: versioned_product, variant: versioned_product.alive_variants.first, quantity: 3) }

      let(:purchase) { create(:purchase, link: bundle, purchaser:, zip_code: "12345", purchase_custom_fields: [build(:purchase_custom_field, name: "Key", value: "Value", bundle_product:)]) }

      it "creates bundle product purchase artifacts" do
        purchase.create_artifacts_and_send_receipt!

        purchase.reload
        expect(purchase.is_bundle_purchase).to eq(true)
        expect(purchase.product_purchases.count).to eq(2)
        expect(purchase.purchase_custom_fields).to be_empty

        product_purchase2 = Purchase.last
        expect(product_purchase2.link).to eq(versioned_product)
        expect(product_purchase2.quantity).to eq(3)
        expect(product_purchase2.variant_attributes).to eq([versioned_product.alive_variants.first])

        product_purchase1 = Purchase.second_to_last
        expect(product_purchase1.link).to eq(product)
        expect(product_purchase1.quantity).to eq(1)
        expect(product_purchase1.variant_attributes).to eq([])
        expect(product_purchase1.purchase_custom_fields.sole).to have_attributes(name: "Key", value: "Value", bundle_product: nil)

        [product_purchase1, product_purchase2].each do |product_purchase|
          expect(product_purchase.total_transaction_cents).to eq(0)
          expect(product_purchase.displayed_price_cents).to eq(0)
          expect(product_purchase.fee_cents).to eq(0)
          expect(product_purchase.price_cents).to eq(0)
          expect(product_purchase.gumroad_tax_cents).to eq(0)
          expect(product_purchase.shipping_cents).to eq(0)

          expect(product_purchase.is_bundle_product_purchase).to eq(true)
          expect(product_purchase.is_bundle_purchase).to eq(false)

          expect(product_purchase.purchaser).to eq(purchaser)
          expect(product_purchase.email).to eq(purchase.email)
          expect(product_purchase.full_name).to eq(purchase.full_name)
          expect(product_purchase.street_address).to eq(purchase.street_address)
          expect(product_purchase.country).to eq(purchase.country)
          expect(product_purchase.state).to eq(purchase.state)
          expect(product_purchase.zip_code).to eq(purchase.zip_code)
          expect(product_purchase.city).to eq(purchase.city)
          expect(product_purchase.ip_address).to eq(purchase.ip_address)
          expect(product_purchase.ip_state).to eq(purchase.ip_state)
          expect(product_purchase.ip_country).to eq(purchase.ip_country)
          expect(product_purchase.browser_guid).to eq(purchase.browser_guid)
          expect(product_purchase.referrer).to eq(purchase.referrer)
          expect(product_purchase.was_product_recommended).to eq(purchase.was_product_recommended)
        end

        expect(purchase.product_purchases).to eq([product_purchase1, product_purchase2])
      end
    end

    context "purchase is a bundle product purchase" do
      let(:purchase) { create(:purchase, is_bundle_product_purchase: true) }

      it "doesn't send the receipt" do
        expect { purchase.notify_seller! }.to_not have_enqueued_mail(CustomerMailer, :receipt)
      end
    end
  end

  describe "#mark_product_purchases_as_chargedback!" do
    let(:purchase) { create(:purchase, link: create(:product, :bundle)) }

    before do
      purchase.create_artifacts_and_send_receipt!
    end

    it "marks all bundle purchases as charged back" do
      expect(purchase.product_purchases.first.chargeback_date).to be_nil
      expect(purchase.product_purchases.second.chargeback_date).to be_nil
      purchase.mark_product_purchases_as_chargedback!
      expect(purchase.product_purchases.first.chargeback_date).to_not be_nil
      expect(purchase.product_purchases.second.chargeback_date).to_not be_nil
    end
  end

  describe "#mark_product_purchases_as_chargeback_reversed!" do
    let(:purchase) { create(:purchase, link: create(:product, :bundle)) }

    before do
      purchase.create_artifacts_and_send_receipt!
    end

    it "marks all bundle purchases as chargeback reversed" do
      expect(purchase.product_purchases.first.chargeback_reversed).to eq(false)
      expect(purchase.product_purchases.second.chargeback_reversed).to eq(false)
      purchase.mark_product_purchases_as_chargeback_reversed!
      expect(purchase.product_purchases.first.chargeback_reversed).to eq(true)
      expect(purchase.product_purchases.second.chargeback_reversed).to eq(true)
    end
  end

  describe "#has_content?" do
    before :each do
      allow(purchase).to receive(:webhook_failed).and_return false
    end

    context "when the purchased product has product files" do
      let(:product) { create(:product_with_files) }
      let(:purchase) { create(:purchase, link: product) }
      let!(:url_redirect) { create(:url_redirect, purchase:, link: product) }

      it "returns true if webhook did not fail, pdf stamp is disabled and url redirect is present" do
        expect(purchase.has_content?).to be(true)
      end

      it "returns false if webhook has falied" do
        allow(purchase).to receive(:webhook_failed).and_return true
        expect(purchase.has_content?).to be(false)
      end

      it "returns false if product has stampable files but the stamping hasn't finished" do
        product.product_files << create(:readable_document, pdf_stamp_enabled: true)

        expect(purchase.has_content?).to be(false)
      end

      it "returns true if product has stampable files and the stamping has finished" do
        product.product_files << create(:readable_document, pdf_stamp_enabled: true)

        allow(url_redirect).to receive(:is_done_pdf_stamping).and_return true
        expect(purchase.has_content?).to be(true)
      end

      it "returns false if url redirect is nil" do
        allow(purchase).to receive(:url_redirect).and_return nil
        expect(purchase.has_content?).to be(false)
      end
    end

    context "when the purchased product does not have product files" do
      let(:product) { create(:product) }
      let(:purchase) { create(:purchase, link: product) }
      let!(:url_redirect) { create(:url_redirect, purchase:, link: product) }

      it "returns true" do
        expect(purchase.has_content?).to be(true)
      end
    end
  end

  describe "#successful_and_valid?" do
    it "returns true if is is successful, not charged back, not refunded and not additional contribution" do
      purchase = create(:purchase, purchase_state: "successful", chargeback_date: nil, stripe_refunded: false)
      expect(purchase.successful_and_valid?).to be(true)
    end

    it "returns false if it is not successful" do
      purchase = create(:purchase, purchase_state: "failed", chargeback_date: nil, stripe_refunded: false)
      expect(purchase.successful_and_valid?).to be(false)
    end

    it "returns false if it has been charged back" do
      purchase = create(:purchase, purchase_state: "successful", chargeback_date: DateTime.current, stripe_refunded: false)
      expect(purchase.successful_and_valid?).to be(false)
    end

    it "returns false if it has been refunded" do
      purchase = create(:purchase, purchase_state: "successful", chargeback_date: nil, stripe_refunded: true)
      expect(purchase.successful_and_valid?).to be(false)
    end

    it "returns false if it is a test purchase" do
      link = create(:product)
      purchase = create(:purchase, link:, purchaser: link.user, purchase_state: "test_successful", chargeback_date: nil, stripe_refunded: false)
      expect(purchase.successful_and_valid?).to be(false)
    end

    describe "subscription purchase" do
      before do
        @subscription_link = create(:subscription_product)
        @subscription = create(:subscription)
        @original_purchase = create(:purchase, link: @subscription_link, subscription: @subscription, purchase_state: "successful",
                                               chargeback_date: nil, stripe_refunded: false, is_original_subscription_purchase: true)
        @subscription_purchase = create(:purchase, link: @subscription_link, subscription: @subscription, purchase_state: "successful",
                                                   chargeback_date: nil, stripe_refunded: false)
      end

      it "returns true if it has not been cancelled nor failed" do
        expect(@subscription_purchase.successful_and_valid?).to be(true)
      end

      it "returns true if the subscription has been upgraded" do
        @original_purchase.update!(is_archived_original_subscription_purchase: true)
        new_original_purchase = create(:purchase, link: @subscription_link, subscription: @subscription, purchase_state: "not_charged",
                                                  chargeback_date: nil, stripe_refunded: false, is_original_subscription_purchase: true)

        expect(new_original_purchase.successful_and_valid?).to be(true)
      end

      it "returns false if it has been cancelled" do
        allow(@subscription).to receive(:cancelled_at).and_return(DateTime.current)
        expect(@subscription_purchase.successful_and_valid?).to be(false)
      end

      it "returns false if it has been failed" do
        allow(@subscription).to receive(:failed_at).and_return(DateTime.current)
        expect(@subscription_purchase.successful_and_valid?).to be(false)
      end
    end
  end

  describe "#successful_and_not_reversed?" do
    context "when include_gift is false" do
      it "returns true for a successful purchase" do
        ["preorder_authorization_successful", "successful", "not_charged"].map do |successful_state|
          purchase = build(:purchase, purchase_state: successful_state)
          expect(purchase.successful_and_not_reversed?).to eq true
        end
      end

      it "returns false for a successful chargedback purchase" do
        purchase = build(:purchase, purchase_state: "successful", chargeback_date: 1.day.ago)
        expect(purchase.successful_and_not_reversed?).to eq false
      end

      it "returns false for a successful refunded purchase" do
        purchase = build(:purchase, purchase_state: "successful", stripe_refunded: true)
        expect(purchase.successful_and_not_reversed?).to eq false
      end

      it "returns false for a received gift purchase" do
        purchase = build(:purchase, :gift_receiver)
        expect(purchase.successful_and_not_reversed?).to eq false
      end
    end

    context "when include_gift is true" do
      it "returns true for a successful purchase" do
        ["preorder_authorization_successful", "successful", "not_charged"].map do |successful_state|
          purchase = build(:purchase, purchase_state: successful_state)
          expect(purchase.successful_and_not_reversed?(include_gift: true)).to eq true
        end
      end

      it "returns false for a successful chargedback purchase" do
        purchase = build(:purchase, purchase_state: "successful", chargeback_date: 1.day.ago)
        expect(purchase.successful_and_not_reversed?(include_gift: true)).to eq false
      end

      it "returns false for a successful refunded purchase" do
        purchase = build(:purchase, purchase_state: "successful", stripe_refunded: true)
        expect(purchase.successful_and_not_reversed?(include_gift: true)).to eq false
      end

      it "returns false for a received gift purchase" do
        purchase = build(:purchase, :gift_receiver)
        expect(purchase.successful_and_not_reversed?(include_gift: true)).to eq true
      end
    end
  end

  describe "when the user specifies their own zip (e.g. via shipping)" do
    def parse_zip(user_input_zip)
      create(:purchase, zip_code: user_input_zip, country: "United States").send(:parsed_zip_from_user_input)
    end

    it "correctly parses the zip from different formats" do
      expect(parse_zip("94301")).to eq("94301")
      expect(parse_zip("02912-9001")).to eq("02912")
      expect(parse_zip(" 90210")).to eq("90210")
      expect(parse_zip("90210 ")).to eq("90210")
      expect(parse_zip("029129001")).to eq("02912")
      expect(parse_zip("20394023492034")).to be(nil)
      expect(parse_zip("j#*(#/asdfie3 sdf3")).to be(nil)
      expect(parse_zip("string90210morestring")).to be(nil)
      expect(parse_zip("94301sdflkj")).to be(nil)
      expect(parse_zip("10016 7808")).to eq("10016")
    end
  end

  describe "when a product's sales number changes" do
    before do
      @product = create(:product)
      @purchase = create(:purchase, link: @product, purchase_state: "in_progress")
    end

    it "schedules a sidekiq job to invalidate the product's cache in 1 minute" do
      @purchase.mark_successful!
      expect(InvalidateProductCacheWorker).to have_enqueued_sidekiq_job(@purchase.link.id).in(1.minute)
    end
  end

  describe "successful purchase" do
    before do
      @user = create(:user)
      @product = create(:physical_product, user: @user)
      @product.skus_enabled = true
      @product.save!
      category = create(:variant_category, link: @product)
      @variant1 = create(:variant, variant_category: category)
      @variant2 = create(:variant, variant_category: category)
      Product::SkusUpdaterService.new(product: @product).perform
      @sku = Sku.last
      @sku.update_column(:max_purchase_count, 10)
      @purchase = create(:physical_purchase, link: @product, variant_attributes: [@sku], seller: @product.user, purchase_state: "in_progress")
    end

    it "schedules a sidekiq job to invalidate the product's cache on inventory change in 1 minute" do
      @purchase.variant_attributes = []
      @purchase.save!
      @product.update_column(:max_purchase_count, 10)

      @purchase.update_balance_and_mark_successful!
      expect(InvalidateProductCacheWorker).to have_enqueued_sidekiq_job(@purchase.link.id).in(1.minute)
    end

    it "sets updated_at on the sku" do
      category1 = create(:variant_category, title: "Size", link: @product)
      create(:variant, variant_category: category1, name: "Small")
      category2 = create(:variant_category, title: "Color", link: @product)
      create(:variant, variant_category: category2, name: "Red")
      travel_to(1.minute.ago) { Product::SkusUpdaterService.new(product: @product).perform }
      @product.update_column(:max_purchase_count, 10)
      chargeable = build(:chargeable)
      purchase = build(:physical_purchase, link: @product, chargeable:, perceived_price_cents: 100, save_card: false, price_range: 1, purchase_state: "in_progress")
      purchase.variant_attributes << Sku.last

      travel_to(Time.current) do
        purchase.mark_successful
        expect(@product.skus.last.updated_at.to_i).to eq Time.current.to_i
      end
    end
  end

  describe "probation" do
    before do
      @product = create(:physical_product, user: create(:compliant_user))
      @purchase = build(:physical_purchase, link: @product, variant_attributes: [@product.skus.last], seller: @product.user, purchase_state: "in_progress")
    end

    it "does not put the seller on probation for expensive sales" do
      @purchase.update!(price_cents: 1000_00)

      @purchase.mark_successful!

      expect(@purchase.seller.on_probation?).to be(false)
    end
  end

  describe "licenses" do
    before do
      gifter_email = "gifter@foo.com"
      giftee_email = "giftee@foo.com"
      @product = create(:product, is_licensed: true)
      gift = create(:gift, gifter_email:, giftee_email:, link: @product)

      @gifter_purchase = create(:purchase, link: @product, seller: @product.user, price_cents: @product.price_cents,
                                           email: gifter_email, purchase_state: "in_progress")
      gift.gifter_purchase = @gifter_purchase
      @gifter_purchase.is_gift_sender_purchase = true
      @gifter_purchase.save!

      @giftee_purchase = gift.giftee_purchase = create(:purchase, link: @product, seller: @product.user, email: giftee_email, price_cents: 0,
                                                                  stripe_transaction_id: nil, stripe_fingerprint: nil,
                                                                  is_gift_receiver_purchase: true, purchase_state: "in_progress")
      gift.mark_successful
      gift.save!
    end

    it "does not create a license for the gifter" do
      @giftee_purchase.mark_gift_receiver_purchase_successful
      expect(@gifter_purchase.reload.license).to be(nil)
      expect(@giftee_purchase.reload.license).to_not be(nil)
    end

    it "has the same license key for all subsequent purchases of a subscription as the original purchase" do
      user = create(:user)
      subscription = create(:subscription, user:, link: @product)
      original_subscription_purchase = create(:purchase, link: @product, email: user.email, is_original_subscription_purchase: true,
                                                         subscription:, purchase_state: "in_progress")

      original_subscription_purchase.mark_successful!
      expect(original_subscription_purchase.license.serial).to_not be_nil

      recurring_purchase = create(:purchase, link: @product, email: user.email, is_original_subscription_purchase: false,
                                             subscription:, purchase_state: "in_progress")
      recurring_purchase.mark_successful!
      expect(recurring_purchase.license.serial).to eq original_subscription_purchase.license.serial
    end

    describe "#license_json" do
      it "returns the license information" do
        purchase = create(:purchase, link: @product)
        license = create(:license, purchase:)

        expect(purchase.send(:license_json)).to eq ({
          license_key: license.serial,
          license_id: license.external_id,
          license_disabled: false,
          is_multiseat_license: false,
        })
      end

      context "when multiseat is disabled" do
        it "returns `is_multiseat_license` as false" do
          purchase = create(:purchase, link: @product)
          license = create(:license, purchase:)

          expect(purchase.send(:license_json)).to eq ({
            license_key: license.serial,
            license_id: license.external_id,
            license_disabled: false,
            is_multiseat_license: false
          })
        end
      end

      context "when multiseat is enabled" do
        it "returns `is_multiseat_license` as true" do
          @product.update(is_multiseat_license: true)
          purchase = create(:purchase, link: @product)
          license = create(:license, purchase:)

          expect(purchase.send(:license_json)).to eq ({
            license_key: license.serial,
            license_id: license.external_id,
            license_disabled: false,
            is_multiseat_license: true
          })
        end
      end
    end
  end

  describe "variant_names_hash" do
    before do
      @product = create(:physical_product, skus_enabled: true)
      @category1 = create(:variant_category, title: "Size", link: @product)
      @variant1 = create(:variant, variant_category: @category1, name: "Small")
      @category2 = create(:variant_category, title: "Color", link: @product)
      @variant2 = create(:variant, variant_category: @category2, name: "Red")
      Product::SkusUpdaterService.new(product: @product).perform
      @chargeable = build(:chargeable)
      @purchase = build(:purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 100, save_card: false,
                                   ip_address:, price_range: 1)
      @purchase.variant_attributes << Sku.last
    end

    it "returns the selected SKU regardless of skus_enabled" do
      @purchase.process!
      @purchase.link.update!(skus_enabled: false)
      expect(@purchase.variant_names_hash).to eq("Size - Color" => "Small - Red")
    end

    it "returns the selected variants regardless of skus_enabled" do
      @purchase.variant_attributes.clear
      @purchase.variant_attributes << [@variant1, @variant2]
      expect(@purchase.variant_names_hash).to eq("Size" => "Small", "Color" => "Red")
    end
  end

  describe "referrer" do
    it "truncates the referrer and then save it" do
      purchase = create(:purchase, referrer: "a" * 1000)
      expect(purchase.referrer).to eq("a" * 191)
    end
  end

  describe "#schedule_subscription_jobs" do
    before do
      @product = create(:membership_product, subscription_duration: BasePrice::Recurrence::MONTHLY)
      @subscription = create(:subscription, link: @product, charge_occurrence_count: 2)
      create(:purchase, link: @product, is_original_subscription_purchase: true, subscription: @subscription)
    end

    it "schedules the job to end the subscription if the set number of charges have completed" do
      purchase = create(:purchase_in_progress, link: @product, subscription: @subscription)
      purchase.process!

      travel_to(Time.current)

      purchase.mark_successful!
      expect(EndSubscriptionWorker).to have_enqueued_sidekiq_job(@subscription.id).at(1.month.from_now)
    end
  end

  describe "rental expiration reminder emails" do
    before do
      travel_to(Time.zone.parse("2015-03-12T00:00:00Z"))
      @product = create(:product_with_video_file, purchase_type: :buy_and_rent, price_cents: 500, rental_price_cents: 200, name: "rental test")
      @purchase = create(:purchase_with_balance, link: @product, is_rental: true)
    end

    it "has scheduled all 3 reminder email jobs" do
      expect(SendRentalExpiresSoonEmailWorker).to have_enqueued_sidekiq_job(@purchase.id, 1.day).in(29.days)
      expect(SendRentalExpiresSoonEmailWorker).to have_enqueued_sidekiq_job(@purchase.id, 3.days).in(27.days)
      expect(SendRentalExpiresSoonEmailWorker).to have_enqueued_sidekiq_job(@purchase.id, 7.days).in(23.days)
    end
  end

  describe "shipping charges" do
    before do
      @purchase = create(:purchase, price_cents: 100_00, chargeable: create(:chargeable))

      @purchase.link.price_cents = 100_00
      @purchase.link.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2, one_item_rate_cents: 10_00, multiple_items_rate_cents: 5_00)
      @purchase.link.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::GBR.alpha2, one_item_rate_cents: 5_00, multiple_items_rate_cents: 10_00)
      @purchase.link.is_physical = true
      @purchase.link.require_shipping = true
      @purchase.link.user.save!
    end

    it "standalone rate applied when shipped to a region that has a shipping rate configured - qty of 1" do
      @purchase.country = "United States"
      @purchase.zip_code = 94_107
      @purchase.state = "CA"

      @purchase.quantity = 1
      @purchase.save!

      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!)
                                   .with(anything, anything, 110_00, anything, anything, anything, anything)
                                   .and_call_original
      @purchase.process!

      expect(@purchase.price_cents).to eq(110_00)
      expect(@purchase.shipping_cents).to eq(10_00)
      expect(@purchase.tax_cents).to eq(0)
      expect(@purchase.fee_cents).to eq(14_99)
    end

    it "combined rate applied when shipped to a region that has a shipping rate configured - qty of 5" do
      @purchase.country = "United States"
      @purchase.zip_code = 94_107
      @purchase.state = "CA"

      @purchase.quantity = 5
      @purchase.save!

      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!)
                                   .with(anything, anything, 530_00, anything, anything, anything, anything)
                                   .and_call_original
      @purchase.process!

      expect(@purchase.price_cents).to eq(530_00)
      expect(@purchase.shipping_cents).to eq(30_00)
      expect(@purchase.tax_cents).to eq(0)
      expect(@purchase.fee_cents).to eq(69_17)
    end

    describe "virtual countries" do
      it "standalone rate applied when shipped to a region that has a shipping rate configured - qty of 1" do
        @purchase.link.shipping_destinations << ShippingDestination.new(country_code: "EUROPE", one_item_rate_cents: 7_00, multiple_items_rate_cents: 10_00, is_virtual_country: true)
        @purchase.country = "France"
        @purchase.zip_code = 75_001
        @purchase.state = "Ile-de-France"

        @purchase.quantity = 1
        @purchase.save!

        create(:zip_tax_rate, zip_code: 75_001, state: "Ile-de-France", country: Compliance::Countries::FRA.alpha2, combined_rate: 0.1)

        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!)
                                     .with(anything, anything, 107_00, anything, anything, anything, anything)
                                     .and_call_original
        @purchase.process!

        expect(@purchase.price_cents).to eq(107_00)
        expect(@purchase.shipping_cents).to eq(7_00)
        expect(@purchase.tax_cents).to eq(0)
        expect(@purchase.fee_cents).to eq(14_60) # 1070c (10%) + 50c + 310c (2.9% cc fee) + 30c
      end

      it "combined rate applied when shipped to a region that has a shipping rate configured - qty of 5" do
        @purchase.link.shipping_destinations << ShippingDestination.new(country_code: "EUROPE", one_item_rate_cents: 7_00, multiple_items_rate_cents: 10_00, is_virtual_country: true)
        @purchase.country = "France"
        @purchase.zip_code = 75_001
        @purchase.state = "Ile-de-France"

        @purchase.quantity = 5
        @purchase.save!

        create(:zip_tax_rate, zip_code: 75_001, state: "Ile-de-France", country: Compliance::Countries::FRA.alpha2, combined_rate: 0.1)

        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!)
                                     .with(anything, anything, 547_00, anything, anything, anything, anything)
                                     .and_call_original
        @purchase.process!

        expect(@purchase.price_cents).to eq(547_00)
        expect(@purchase.shipping_cents).to eq(47_00)
        expect(@purchase.tax_cents).to eq(0)
        expect(@purchase.fee_cents).to eq(71_36) # 54_70c (10%) + 50c + 1586c (2.9% cc fee) + 30c
      end
    end

    describe "validate shipping" do
      before do
        user = create(:user)
        @phys_link = create(:product, price_cents: 100_00, user:, is_physical: true, require_shipping: true)
      end

      it "does not allow shipping to a region where there is no shipping rate configured" do
        bad_purchase = create(:physical_purchase, price_cents: 100_00, link: @phys_link, chargeable: create(:chargeable), country: "Germany")

        expect(bad_purchase.errors[:base].present?).to be(true)
        expect(bad_purchase.error_code).to eq PurchaseErrorCode::NO_SHIPPING_COUNTRY_CONFIGURED
      end

      it "does not allow shipping to a region that is not compliant" do
        bad_purchase = create(:physical_purchase, price_cents: 100_00, link: @phys_link, chargeable: create(:chargeable), country: "Libya")

        expect(bad_purchase.errors[:base].present?).to be(true)
        expect(bad_purchase.error_code).to eq PurchaseErrorCode::BLOCKED_SHIPPING_COUNTRY
      end
    end

    it "allows to ship to any destinate if ELSEWHERE is a configured shipping region" do
      @purchase.country = "Germany"
      @purchase.link.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 10_00, multiple_items_rate_cents: 5_00)

      @purchase.quantity = 1
      @purchase.save!

      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!)
                                   .with(anything, anything, 110_00, anything, anything, anything, anything)
                                   .and_call_original
      @purchase.process!

      expect(@purchase.price_cents).to eq(110_00)
      expect(@purchase.shipping_cents).to eq(10_00)
      expect(@purchase.fee_cents).to eq(14_99) # 11_10c (10%) + 50c + 319c (2.9% cc fee) + 30c
    end

    it "converts the shipping charges to USD before charging" do
      @purchase.country = "Germany"

      @purchase.link.price_currency_type = "gbp"
      @purchase.link.price_cents = 10000
      @purchase.link.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 10_00, multiple_items_rate_cents: 5_00)
      @purchase.link.save!

      @purchase.quantity = 1
      @purchase.save!

      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!)
                                   .with(anything, anything, @purchase.get_usd_cents("gbp", 110_00), anything, anything, anything, anything)
                                   .and_call_original
      @purchase.process!

      expect(@purchase.price_cents).to eq(@purchase.get_usd_cents("gbp", 110_00))
      expect(@purchase.shipping_cents).to eq(@purchase.get_usd_cents("gbp", 10_00))
      expect(@purchase.fee_cents).to eq((@purchase.get_usd_cents("gbp", 110_00) * 0.129 + 50 + 30).truncate)
    end

    it "returns shipping added to price_cents if the purchase is a test purchase" do
      @purchase.country = "Germany"

      @purchase.link.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 10_00, multiple_items_rate_cents: 5_00)

      @purchase.link.save!

      @purchase.purchaser = @purchase.link.user
      @purchase.quantity = 1
      @purchase.save!

      expect(ChargeProcessor).to_not receive(:charge!)

      @purchase.process!

      @purchase.reload
      expect(@purchase.shipping_cents).to eq(10_00)
      expect(@purchase.price_cents).to eq(110_00)
      expect(@purchase.total_transaction_cents).to eq(110_00)
    end
  end

  describe "validate quantity" do
    before do
      @product = create(:product, price_cents: 100_00)
    end

    it "renders purchases valid if the quantity is 1 or more" do
      purchase = create(:purchase, price_cents: 100_00, link: @product, quantity: 1)

      expect(purchase.errors[:base].present?).to be(false)
      expect(purchase.error_code).to be nil
    end

    it "renders purchases invalid if the quantity is 0 or less" do
      purchase = create(:purchase, price_cents: 0, link: @product, quantity: 0)
      purchase1 = create(:purchase, price_cents: 0, link: @product, quantity: -1)

      expect(purchase.errors[:base].present?).to be(true)
      expect(purchase.error_code).to eq PurchaseErrorCode::INVALID_QUANTITY
      expect(purchase1.errors[:base].present?).to be(true)
      expect(purchase1.error_code).to eq PurchaseErrorCode::INVALID_QUANTITY
    end
  end

  describe "validate is_free_trial_purchase" do
    context "when product has free trial enabled" do
      let(:product) do
        create(:membership_product, :with_free_trial_enabled)
      end
      let(:email) { "subscriber@example.com" }

      it "requires is_free_trial_purchase to be set for initial purchase of product" do
        purchase = build(:membership_purchase, link: product, is_free_trial_purchase: true)
        expect(purchase).to be_valid

        purchase.is_free_trial_purchase = false
        expect(purchase).not_to be_valid
        expect(purchase.errors[:base]).to eq ["purchase should be marked as a free trial purchase"]
      end

      it "does not require is_free_trial_purchase to be set when changing plan" do
        purchase = build(:membership_purchase, link: product, is_updated_original_subscription_purchase: true)
        expect(purchase).to be_valid
      end

      context "when the user has already subscribed" do
        let!(:existing_subscription) do
          purchase = create(:free_trial_membership_purchase, link: product, email:)
          purchase.subscription
        end

        it "allows re-purchasing if the existing subscription(s) have paid charges" do
          create(:purchase, subscription: existing_subscription, link: product, email:, purchase_state: "successful")

          purchase = build(:free_trial_membership_purchase, link: product, email:)
          expect(purchase).to be_valid
        end

        it "does not allow re-purchasing if the existing subscription(s) do not have paid charges" do
          create(:purchase, subscription: existing_subscription, link: product, email:, purchase_state: "successful", stripe_refunded: true)
          create(:purchase, subscription: existing_subscription, link: product, email:, purchase_state: "successful", chargeback_date: 1.day.ago)
          purchase = build(:free_trial_membership_purchase, link: product, email:)

          expect(purchase).not_to be_valid
          expect(purchase.errors[:base]).to eq ["You've already purchased this product and are ineligible for a free trial. Please visit the Manage Membership page to re-start or make changes to your subscription."]
        end
      end

      describe "recurring charges" do
        let(:original_purchase) { create(:membership_purchase, link: product, is_free_trial_purchase: true) }

        it "does not allow is_free_trial_purchase to be set for recurring charges" do
          purchase = build(:purchase, subscription: original_purchase.subscription, link: product, is_free_trial_purchase: true)
          expect(purchase).not_to be_valid
          expect(purchase.errors[:base]).to eq ["recurring charges should not be marked as free trial purchases"]
        end

        it "does not error if is_free_trial_purchase is not set" do
          purchase = build(:purchase, subscription: original_purchase.subscription, link: product)
          expect(purchase).to be_valid
        end
      end
    end

    context "when product does not have free trial enabled" do
      it "does not allow is_free_trial_purchase to be set" do
        purchase = build(:membership_purchase)
        expect(purchase).to be_valid

        purchase.is_free_trial_purchase = true
        expect(purchase).not_to be_valid
        expect(purchase.errors[:base]).to eq ["free trial must be enabled on the product"]
      end

      it "allows is_free_trial_purchase to be set for a pre-existing purchase" do
        purchase = create(:membership_purchase)
        purchase.is_free_trial_purchase = true

        expect(purchase).to be_valid
      end

      it "allows is_free_trial_purchase to be set when changing a subscription plan" do
        purchase = create(:membership_purchase)
        purchase.is_free_trial_purchase = true
        purchase.is_updated_original_subscription_purchase = true

        expect(purchase).to be_valid
      end
    end
  end

  describe "purchase sales tax info" do
    it "creates a purchase sales tax info entry if it does not have one" do
      purchase = create(:purchase, price_cents: 100_00, chargeable: create(:chargeable))
      purchase.sales_tax_country_code_election = Compliance::Countries::DEU.alpha2
      purchase.country = Compliance::Countries::USA.common_name
      purchase.zip_code = "94117"
      purchase.ip_address = "2.47.255.255"

      expect(purchase.purchase_sales_tax_info).to be(nil)

      purchase.process!
      purchase.reload

      actual_purchase_sales_tax_info = Purchase.last.purchase_sales_tax_info
      expect(actual_purchase_sales_tax_info).to_not be(nil)
      expect(actual_purchase_sales_tax_info.elected_country_code).to eq(Compliance::Countries::DEU.alpha2)
      expect(actual_purchase_sales_tax_info.card_country_code).to eq(Compliance::Countries::USA.alpha2)
      expect(actual_purchase_sales_tax_info.postal_code).to eq("94117")
      expect(actual_purchase_sales_tax_info.ip_country_code).to be(nil)
      expect(actual_purchase_sales_tax_info.country_code).to eq(Compliance::Countries::USA.alpha2)
      expect(actual_purchase_sales_tax_info.ip_address).to eq("2.47.255.255")
    end

    it "does not create a purchase sales tax info entry if it already has one" do
      purchase_sales_tax_info = PurchaseSalesTaxInfo.new

      purchase = create(:purchase, price_cents: 100_00, chargeable: create(:chargeable))
      purchase.purchase_sales_tax_info = purchase_sales_tax_info
      purchase.purchase_sales_tax_info.save!

      purchase.process!
      purchase.reload

      expect(purchase.purchase_sales_tax_info).to eq(purchase_sales_tax_info)
    end

    it "handles invalid countries from GEOIP lookup for IP address" do
      purchase = create(:purchase, price_cents: 100_00, chargeable: create(:chargeable))
      purchase.sales_tax_country_code_election = Compliance::Countries::DEU.alpha2
      purchase.country = Compliance::Countries::USA.common_name
      purchase.zip_code = "94117"
      purchase.ip_country = "Invalid country"
      purchase.ip_address = "2.47.255.255"

      purchase.process!
      purchase.reload

      actual_purchase_sales_tax_info = Purchase.last.purchase_sales_tax_info
      expect(actual_purchase_sales_tax_info).to_not be(nil)
      expect(actual_purchase_sales_tax_info.elected_country_code).to eq(Compliance::Countries::DEU.alpha2)
      expect(actual_purchase_sales_tax_info.card_country_code).to eq(Compliance::Countries::USA.alpha2)
      expect(actual_purchase_sales_tax_info.postal_code).to eq("94117")
      expect(actual_purchase_sales_tax_info.ip_country_code).to be(nil)
      expect(actual_purchase_sales_tax_info.country_code).to eq(Compliance::Countries::USA.alpha2)
      expect(actual_purchase_sales_tax_info.ip_address).to eq("2.47.255.255")
    end
  end

  describe "sku_custom_name_or_external_id" do
    before do
      @product = create(:product)
      @purchase = create(:purchase, link: @product)
    end

    describe "with sku" do
      before do
        @product.skus_enabled = true
      end

      it "returns the sku external id" do
        @purchase.variant_attributes << create(:sku)
        expect(@purchase.sku_custom_name_or_external_id).to eq(Sku.last.external_id.to_s)
      end

      it "returns the custom sku" do
        @purchase.variant_attributes << create(:sku, custom_sku: "CUSTOMIZE")
        expect(@purchase.sku_custom_name_or_external_id).to eq("CUSTOMIZE")
      end
    end

    describe "without sku" do
      context "when product is physical and has a variant" do
        let(:variant) { create(:variant) }

        before do
          @product.is_physical = true
          @purchase.variant_attributes << variant
        end

        it "returns the variant external id" do
          expect(@purchase.sku_custom_name_or_external_id).to eq(variant.external_id)
        end
      end

      it "returns the link external id" do
        expect(@purchase.sku_custom_name_or_external_id).to eq("pid_#{@product.external_id}")
      end
    end
  end

  describe "#schedule_workflow_jobs" do
    before do
      creator = create(:user)
      user = create(:user, credit_card: create(:credit_card))
      product = create(:subscription_product, user: creator)
      workflow = create(:workflow, seller: creator, link: product)
      @post = create(:installment, workflow:, published_at: Time.current)
      create(:installment_rule, installment: @post, delayed_delivery_time: 3.days)
      subscription = create(:subscription, user:, link: product)
      create(:purchase, link: product, email: user.email, is_original_subscription_purchase: true, subscription:)
      @recurring_purchase = create(:purchase, link: product, email: user.email, is_original_subscription_purchase: false, subscription:, purchase_state: "in_progress")
    end

    it "does not enqueue the job to schedule workflow emails if recurring payment" do
      @recurring_purchase.mark_successful!

      expect(ScheduleWorkflowEmailsWorker.jobs.size).to eq(0)
    end
  end

  describe "#email_digest" do
    it "returns a HMAC digest of id and email" do
      purchase = create(:purchase, email: "test@example.com")
      key = GlobalConfig.get("OBFUSCATE_IDS_CIPHER_KEY")
      token_data = "#{purchase.id}:#{purchase.email}"
      expected_digest = OpenSSL::HMAC.digest("SHA256", key, token_data)
      base64_encoded_digest = Base64.urlsafe_encode64(expected_digest)

      expect(purchase.email_digest).to eq(base64_encoded_digest)
    end

    it "returns nil when email is blank" do
      purchase = build(:purchase, email: nil)
      expect(purchase.email_digest).to be_nil
    end
  end

  describe "#receipt_url" do
    let(:purchase) { create(:purchase) }

    it "returns the correct receipt URL" do
      expected_url = "#{PROTOCOL}://#{DOMAIN}/purchases/#{purchase.external_id}/receipt?email=#{CGI.escape(purchase.email)}"
      expect(purchase.receipt_url).to eq(expected_url)
    end
  end

  describe "email" do
    describe "on create" do
      describe "valid email" do
        let(:purchase) do
          purchase = build(:purchase)
          purchase.save
          purchase
        end

        it "is valid" do
          expect(purchase).to be_valid
        end
      end

      describe "invalid email" do
        let(:purchase) do
          # email invalid because it contains trailing whitespace
          purchase = build(:purchase, email: "hi@gumroad.com ")
          purchase.save
          purchase
        end

        it "is invalid" do
          expect(purchase).not_to be_valid
        end
      end
    end

    describe "on update" do
      describe "valid email" do
        let(:purchase) { create(:purchase) }

        before do
          purchase.updated_at = Time.current
          purchase.save
        end

        it "is valid" do
          expect(purchase).to be_valid
        end
      end

      describe "invalid email" do
        let(:purchase) do
          # email invalid because it contains trailing whitespace
          purchase = build(:purchase, email: "hi@gumroad.com ")
          purchase.save(validate: false)
          purchase
        end

        before do
          purchase.updated_at = Time.current
          purchase.save
        end

        it "is valid" do
          expect(purchase).to be_valid
        end
      end
    end
  end

  describe ".counts_towards_inventory" do
    it "only includes purchases that could become successful" do
      product = create(:product)
      success = create(:purchase, link: product)
      success_preorder_auth = create(:purchase, link: product, purchase_state: "preorder_authorization_successful")
      create(:purchase, link: product, purchase_state: "failed")
      in_progress = create(:purchase, link: product, purchase_state: "in_progress")

      expect(Purchase.counts_towards_inventory).to match_array([success, success_preorder_auth, in_progress])
    end

    it "excludes recurring charges" do
      product = create(:product)
      subscription = create(:subscription, link: product)
      initial_purchase = create(:purchase, link: product, subscription:, is_original_subscription_purchase: true)
      create(:purchase, link: product, subscription:, is_original_subscription_purchase: false)

      expect(Purchase.counts_towards_inventory).to match_array([initial_purchase])
    end

    it "excludes additional contributions" do
      create(:purchase, is_additional_contribution: true)

      expect(Purchase.counts_towards_inventory).to be_empty
    end

    it "excludes archived original subscription purchases" do
      purchase = create(:purchase, is_archived_original_subscription_purchase: true)

      expect(Purchase.counts_towards_inventory).not_to match_array([purchase])
    end

    context "memberships with tiers" do
      it "only counts active memberships + non-subscription sales" do
        non_subscription_purchase = create(:purchase)

        membership_product = create(:membership_product)
        active_subscription = create(:subscription, link: membership_product)
        active_purchase = create(:purchase, link: membership_product, subscription: active_subscription, is_original_subscription_purchase: true)
        inactive_subscription = create(:subscription, link: membership_product, deactivated_at: Time.current)
        create(:purchase, link: membership_product, subscription: inactive_subscription, is_original_subscription_purchase: true)
        non_subscription_purchase_of_membership_product = create(:purchase, link: membership_product)
        free_trial_purchase = create(:free_trial_membership_purchase)

        expect(Purchase.counts_towards_inventory).to match_array([
                                                                   active_purchase,
                                                                   non_subscription_purchase,
                                                                   non_subscription_purchase_of_membership_product,
                                                                   free_trial_purchase,
                                                                 ])
      end
    end
  end

  describe ".counts_towards_offer_code_uses" do
    it "includes successful purchases" do
      purchase = create(:purchase, purchase_state: "successful")
      expect(Purchase.counts_towards_offer_code_uses).to match_array [purchase]
    end

    it "includes preorder authorization purchases" do
      purchase = create(:preorder_authorization_purchase)
      expect(Purchase.counts_towards_offer_code_uses).to match_array [purchase]
    end

    it "includes original (non-archived) membership purchases" do
      purchase = create(:membership_purchase)
      expect(Purchase.counts_towards_offer_code_uses).to match_array [purchase]
    end

    it "includes free trial membership purchases" do
      purchase = create(:free_trial_membership_purchase)
      expect(Purchase.counts_towards_offer_code_uses).to match_array [purchase]
    end

    it "excludes other purchases" do
      create(:failed_purchase)
      create(:purchase, purchase_state: "test_successful")
      create(:purchase, purchase_state: "gift_receiver_purchase_successful")
      original_purchase = create(:recurring_membership_purchase, is_original_subscription_purchase: false).original_purchase
      create(:membership_purchase, is_archived_original_subscription_purchase: true)
      expect(Purchase.where.not(id: original_purchase.id).counts_towards_offer_code_uses).to eq []
    end
  end

  describe ".counts_towards_volume" do
    it "includes successful purchases" do
      purchase = create(:purchase, purchase_state: "successful")
      expect(Purchase.counts_towards_volume).to match_array [purchase]
    end

    it "excludes other purchases" do
      create(:failed_purchase)
      create(:purchase, purchase_state: "test_successful")
      create(:purchase, purchase_state: "gift_receiver_purchase_successful")
      create(:purchase, price_cents: 300, stripe_refunded: true)
      create(:purchase, chargeback_date: Date.yesterday)
      expect(Purchase.counts_towards_volume).to eq []
    end
  end

  describe "has_active_subscription" do
    before do
      @subscription = create(:subscription)
      @purchase = create(:purchase, subscription: @subscription, is_original_subscription_purchase: true)
    end

    it "does not include cancelled subscriptions" do
      @subscription.update_attribute(:cancelled_at, Time.current)
      expect(@purchase.has_active_subscription?).to eq(false)
    end

    it "does not include failed subscriptions" do
      @subscription.update_attribute(:failed_at, Time.current)
      expect(@purchase.has_active_subscription?).to eq(false)
    end

    it "does not include ended subscriptions" do
      @subscription.update_attribute(:ended_at, Time.current)
      expect(@purchase.has_active_subscription?).to eq(false)
    end

    it "does not include pending cancellation subscriptions" do
      @subscription.update_attribute(:cancelled_at, 1.hour.from_now)
      expect(@purchase.has_active_subscription?).to eq(false)
    end
  end

  describe "#charge_discover_fee?" do
    before do
      @purchase = create(:purchase, was_product_recommended: false)
    end

    it "is false if the purchase is not recommended" do
      expect(@purchase.send(:charge_discover_fee?)).to eq(false)
    end

    it "returns true if the purchase is recommended" do
      @purchase.was_product_recommended = true
      @purchase.save
      expect(@purchase.send(:charge_discover_fee?)).to eq(true)
      @purchase.seller.recommendation_type = User::RecommendationType::NO_RECOMMENDATIONS
      @purchase.seller.save
      expect(@purchase.send(:charge_discover_fee?)).to eq(true)
    end

    it "returns false if the purchase is recommended by library or more like this" do
      expect(@purchase.send(:charge_discover_fee?)).to eq(false)

      @purchase.update!(was_product_recommended: true)
      expect(@purchase.send(:charge_discover_fee?)).to eq(true)

      RecommendationType.all.each do |recommendation_type|
        @purchase.update!(recommended_by: recommendation_type)
        expect(@purchase.was_product_recommended?).to eq(true)
        expect(@purchase.send(:charge_discover_fee?)).to eq(!RecommendationType.is_free_recommendation_type?(recommendation_type))
      end
    end
  end

  describe "paypal purchase failure" do
    before do
      @purchase = build(:purchase_with_balance, save_card: true, chargeable: build(:paypal_chargeable))
      @purchase.process!
    end

    it "emails the buyer saying the purchase failed" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(CustomerMailer).to receive(:paypal_purchase_failed).and_return(mail_double)
      @purchase.mark_failed
    end

    it "emails the buyer saying the purchase failed for native paypal too" do
      @purchase.charge_processor_id = "paypal"
      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(CustomerMailer).to receive(:paypal_purchase_failed).and_return(mail_double)
      @purchase.mark_failed
    end

    it "doesn't email the buyer if not a paypal purchase" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect { @purchase.mark_failed }.to change { ActionMailer::Base.deliveries.count }.by(0)
    end
  end

  describe "#upload_invoice_pdf" do
    before(:each) do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/purchase-invoice-spec-#{SecureRandom.hex(18)}")

      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).with(INVOICES_S3_BUCKET).and_return(s3_bucket_double)

      expect(s3_bucket_double).to receive_message_chain(:object).and_return(@s3_object)
    end

    it "writes the passed file to S3 and returns the S3 object" do
      purchase = create(:purchase)
      file = File.open(Rails.root.join("spec", "support", "fixtures", "smaller.png"))

      result = purchase.upload_invoice_pdf(file)
      expect(result).to be(@s3_object)
      expect(result.content_length).to eq(file.size)
    end
  end

  describe "#unsubscribe_buyer" do
    before do
      seller_a = create(:user)
      seller_b = create(:user)
      buyer = create(:user)

      product_1_by_seller_a = create(:product, user: seller_a)
      product_2_by_seller_a = create(:product, user: seller_a)
      product_3_by_seller_b = create(:product, user: seller_b)

      @purchase_of_product_1 = create(:purchase, link: product_1_by_seller_a, email: buyer.email)
      @purchase_of_product_2 = create(:purchase, link: product_2_by_seller_a, email: buyer.email)
      @purchase_of_product_3 = create(:purchase, link: product_3_by_seller_b, email: buyer.email)

      @follower_of_seller_a = create(:active_follower, email: @purchase_of_product_1.email, followed_id: @purchase_of_product_1.seller_id)
      @follower_of_seller_b = create(:active_follower, email: @purchase_of_product_3.email, followed_id: @purchase_of_product_3.seller_id)
    end

    it "unsubcribes the buyer of the purchase from all sales made by the seller" do
      expect do
        @purchase_of_product_1.unsubscribe_buyer
      end.to change {
        [
          @purchase_of_product_1.reload.can_contact,
          @purchase_of_product_2.reload.can_contact,
          @purchase_of_product_3.reload.can_contact,
          @follower_of_seller_a.reload.deleted_at.nil?,
          @follower_of_seller_b.reload.deleted_at.nil?
        ]
      }.from([true, true, true, true, true]).to([false, false, true, false, true])
    end

    context "when purchase record is invalid" do
      before do
        @purchase_of_product_1.update_column(:merchant_account_id, nil)
        expect(@purchase_of_product_1.valid?).to eq(false) # Ensure that the record currently fails validation
      end

      it "unsubscribes the buyer without running validations" do
        expect(Rails.logger).to receive(:info).with("Could not update purchase (#{@purchase_of_product_1.id}) with validations turned on. Unsubscribing the buyer without running validations.").and_call_original
        expect { @purchase_of_product_1.unsubscribe_buyer }.to change { @purchase_of_product_1.reload.can_contact }.from(true).to(false)
      end
    end
  end

  describe "#attach_credit_card_to_purchaser" do
    it "the method is not called when the purchaser_id is not updated" do
      user = create(:user)
      subscription = create(:subscription, user:)
      purchase = create(:purchase, purchaser: user, subscription:,
                                   is_original_subscription_purchase: true)

      expect(purchase).to_not receive(:attach_credit_card_to_purchaser)

      purchase.email = generate(:email)
      purchase.save!
    end

    it "the method is not called when the purchaser_id is set to `nil`" do
      user = create(:user)
      subscription = create(:subscription, user:)
      purchase = create(:purchase, purchaser: user, subscription:,
                                   is_original_subscription_purchase: true)

      expect(purchase).to_not receive(:attach_credit_card_to_purchaser)

      purchase.purchaser_id = nil
      purchase.save!
    end

    it "the method is not called for non-subscription purchases" do
      purchase = create(:purchase, purchaser: create(:user))

      expect(purchase).to_not receive(:attach_credit_card_to_purchaser)

      purchase.purchaser_id = create(:user).id
      purchase.save!
    end

    context "when changing the purchaser id" do
      let(:user) { create(:user) }
      let(:subscription) { create(:subscription, user:) }
      let(:purchase) do
        create(:purchase, purchaser: user,
                          subscription:,
                          is_original_subscription_purchase: true)
      end

      context "when :attach_credit_card_to_purchaser feature is disabled" do
        it "does not call the method" do
          expect(purchase).not_to receive(:attach_credit_card_to_purchaser)

          purchase.purchaser_id = create(:user).id
          purchase.save!
        end
      end

      context "when :attach_credit_card_to_purchaser feature is enabled" do
        before { Feature.activate(:attach_credit_card_to_purchaser) }

        it "calls the method" do
          expect(purchase).to receive(:attach_credit_card_to_purchaser).and_call_original

          purchase.purchaser_id = create(:user).id
          purchase.save!
        end

        it "attaches the credit card of the latest successful purchase to the purchaser" do
          latest_eligible_cc = create(:credit_card)

          purchase = create(:purchase, subscription:, credit_card: create(:credit_card),
                                       is_original_subscription_purchase: true, created_at: 30.minutes.ago)
          create(:purchase, purchaser: user, credit_card: create(:credit_card),
                            created_at: 25.minutes.ago)
          create(:purchase, purchaser: user, credit_card: latest_eligible_cc,
                            created_at: 20.minutes.ago)
          create(:purchase, purchaser: user, created_at: 15.minutes.ago)
          create(:purchase, purchaser: user, purchase_state: "failed",
                            credit_card: create(:credit_card), created_at: 10.minutes.ago)
          create(:purchase, credit_card: create(:credit_card), created_at: 5.minutes.ago)

          expect do
            expect(purchase).to receive(:attach_credit_card_to_purchaser).and_call_original

            purchase.purchaser = user
            purchase.save!
          end.to change { user.reload.credit_card }.from(nil).to(latest_eligible_cc)
        end

        it "does not attempt to attach a credit card to the purchaser if one already exists" do
          user = create(:user, credit_card: create(:credit_card))
          purchase = create(:purchase, subscription:, credit_card: create(:credit_card),
                                       is_original_subscription_purchase: true)

          expect do
            expect(purchase).to receive(:attach_credit_card_to_purchaser).and_call_original

            purchase.purchaser = user
            purchase.save!
          end.to_not change { user.reload.credit_card }
        end
      end
    end
  end

  describe "#update_rental_expired" do
    it "updates rental_expired field if is_rental is set to false" do
      purchase = create(:purchase, is_rental: true, rental_expired: true)
      purchase.is_rental = false
      purchase.save!
      expect(purchase.rental_expired).to eq(nil)
    end
  end

  describe "#trigger_iffy_moderation" do
    let(:purchase) { build(:purchase_in_progress, price_cents: 1000) }

    before { $redis.set(RedisKey.iffy_moderation_probability, "0.5") }

    context "when random number is less than probability" do
      before do
        $redis.set(RedisKey.iffy_moderation_probability, "0.5")
        allow(purchase).to receive(:rand).and_return(0.4)
      end

      it "enqueues Iffy::Product::IngestJob" do
        purchase.update_balance_and_mark_successful!
        expect(Iffy::Product::IngestJob).to have_enqueued_sidekiq_job(purchase.link.id)
      end
    end

    it "does not enqueue Iffy::Product::IngestJob when random number is higher than probability" do
      allow(purchase).to receive(:rand).and_return(0.6)
      purchase.update_balance_and_mark_successful!
      expect(Iffy::Product::IngestJob).not_to have_enqueued_sidekiq_job(purchase.link.id)
    end

    context "when purchase is free" do
      let(:purchase) { build(:purchase_in_progress, price_cents: 0) }

      it "does not enqueue Iffy::Product::IngestJob" do
        purchase.update_balance_and_mark_successful!
        expect(Iffy::Product::IngestJob).not_to have_enqueued_sidekiq_job(purchase.link.id)
      end
    end

    context "when iffy_moderation_probability redis key is not set" do
      before { $redis.del(RedisKey.iffy_moderation_probability) }

      it "uses probability of 0" do
        allow(purchase).to receive(:rand).and_return(0)
        purchase.update_balance_and_mark_successful!
        expect(Iffy::Product::IngestJob).not_to have_enqueued_sidekiq_job(purchase.link.id)
      end
    end

    context "when product has already been moderated by iffy" do
      let(:purchase) { build(:purchase_in_progress, price_cents: 1000, link: create(:product, moderated_by_iffy: true)) }

      it "does not enqueue Iffy::Product::IngestJob" do
        purchase.update_balance_and_mark_successful!
        expect(Iffy::Product::IngestJob).not_to have_enqueued_sidekiq_job(purchase.link.id)
      end
    end
  end

  describe ".formatted_error_code" do
    it "falls back to purchase.stripe_error_code" do
      purchase = create(:purchase, stripe_error_code: "error_code")
      expect(purchase.formatted_error_code).to eq("Error Code")
    end

    it "falls back to purchase.error_code if purchase.stripe_error_code is empty" do
      purchase = create(:purchase, stripe_error_code: nil, error_code: "stripe_error_code")
      expect(purchase.formatted_error_code).to eq("Stripe Error Code")
    end

    it "displays corresponding stripe message for purchase.stripe_error_code" do
      purchase = create(:purchase,
                        charge_processor_id: StripeChargeProcessor.charge_processor_id,
                        stripe_error_code: "card_declined_do_not_honor")
      expect(purchase.formatted_error_code).to eq(PurchaseErrorCode::STRIPE_ERROR_CODES["do_not_honor"])
    end

    it "displays corresponding paypal message for purchase.stripe_error_code" do
      purchase = create(:purchase,
                        charge_processor_id: BraintreeChargeProcessor.charge_processor_id,
                        stripe_error_code: "2000")
      expect(purchase.formatted_error_code).to eq(PurchaseErrorCode::PAYPAL_ERROR_CODES["2000"])
    end

    it "displays corresponding paypal message for purchase.stripe_error_code in case of paypal connect" do
      purchase = create(:purchase,
                        charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                        stripe_error_code: PurchaseErrorCode::PAYPAL_PAYER_CANCELLED_BILLING_AGREEMENT)
      expect(purchase.formatted_error_code).to eq(PurchaseErrorCode::PAYPAL_ERROR_CODES[PurchaseErrorCode::PAYPAL_PAYER_CANCELLED_BILLING_AGREEMENT])
    end
  end

  describe "#has_payment_error?" do
    it "returns true if stripe_error_code is present" do
      purchase = build(:purchase, stripe_error_code: "foo")
      expect(purchase.has_payment_error?).to eq true
    end

    it "returns true if error_code is a payment error code" do
      PurchaseErrorCode::PAYMENT_ERROR_CODES.each do |error_code|
        purchase = build(:purchase, error_code:)
        expect(purchase.has_payment_error?).to eq true
      end
    end

    it "returns true if the purchase has failed" do
      purchase = build(:purchase, purchase_state: "failed")
      expect(purchase.has_payment_error?).to eq true
    end

    it "returns false if error_code is a non-payment error code" do
      purchase = build(:purchase, error_code: "foo")
      expect(purchase.has_payment_error?).to eq false
    end

    it "returns false if error_code and stripe_error_code are not present" do
      purchase = build(:purchase)
      expect(purchase.has_payment_error?).to eq false
    end
  end

  describe "#has_payment_network_error?" do
    it "returns true if error_code is a STRIPE_UNAVAILABLE error" do
      purchase = build(:purchase, error_code: PurchaseErrorCode::STRIPE_UNAVAILABLE)
      expect(purchase.has_payment_network_error?).to eq true
    end

    it "returns true if error_code is a PAYPAL_UNAVAILABLE error" do
      purchase = build(:purchase, error_code: PurchaseErrorCode::PAYPAL_UNAVAILABLE)
      expect(purchase.has_payment_network_error?).to eq true
    end

    it "returns true if stripe_error_code is a PROCESSING_ERROR error" do
      purchase = build(:purchase, stripe_error_code: PurchaseErrorCode::PROCESSING_ERROR)
      expect(purchase.has_payment_network_error?).to eq true
    end

    it "returns false if error_code or stripe_error_code are other errors" do
      purchase = build(:purchase, error_code: "foo")
      expect(purchase.has_payment_network_error?).to eq false

      purchase = build(:purchase, stripe_error_code: "foo")
      expect(purchase.has_payment_network_error?).to eq false
    end

    it "returns false if error_code and stripe_error_code are absent" do
      purchase = build(:purchase)
      expect(purchase.has_payment_network_error?).to eq false
    end
  end

  describe "#has_retryable_payment_error?" do
    it "returns true if stripe_error_code is STRIPE_INSUFFICIENT_FUNDS error" do
      purchase = build(:purchase, stripe_error_code: PurchaseErrorCode::STRIPE_INSUFFICIENT_FUNDS)
      expect(purchase.has_retryable_payment_error?).to eq true
    end

    it "returns false if stripe_error_code is a different error" do
      purchase = build(:purchase, stripe_error_code: PurchaseErrorCode::PROCESSING_ERROR)
      expect(purchase.has_retryable_payment_error?).to eq false
    end

    it "returns false is stripe_error_code is nil" do
      purchase = build(:purchase)
      expect(purchase.has_retryable_payment_error?).to eq false
    end
  end

  describe "#tiers" do
    context "for a non-tiered membership purchase" do
      it "returns an empty array" do
        purchase = create(:purchase)
        expect(purchase.tiers).to eq []
      end
    end

    context "for a tiered membership product" do
      before :each do
        @product = create(:membership_product_with_preset_tiered_pricing)
        @default_tier = @product.default_tier
        @second_tier = @product.tiers.find_by(name: "Second Tier")
      end
      context "that is associated with a tier" do
        it "returns an array containing the tier" do
          purchase = create(:purchase, link: @product, variant_attributes: [@second_tier])
          expect(purchase.tiers).to eq [@second_tier]
        end
      end

      context "that is not associated with a tier" do
        it "returns an array containing the default tier" do
          purchase = create(:purchase, link: @product)
          expect(purchase.tiers).to eq [@default_tier]
        end
      end
    end
  end

  describe "#show_view_content_button_on_product_page?" do
    it "returns true for a tiered membership product with a url redirect" do
      purchase = create(:membership_purchase)
      purchase.create_url_redirect!

      expect(purchase.show_view_content_button_on_product_page?).to be true
    end

    it "returns true if product has attached files" do
      purchase = create(:purchase, link: create(:product_with_files), purchase_state: "in_progress")
      purchase.process!
      purchase.update_balance_and_mark_successful!

      expect(purchase.link.alive_product_files.count).to eq(2)
      expect(purchase.show_view_content_button_on_product_page?).to be true
    end

    it "returns true even if product has no attached files" do
      purchase = create(:purchase, purchase_state: "in_progress")
      purchase.process!
      purchase.update_balance_and_mark_successful!

      expect(purchase.link.alive_product_files.count).to eq(0)
      expect(purchase.show_view_content_button_on_product_page?).to be(true)
    end
  end

  describe "#downcase_email" do
    it "downcases the email when validating" do
      purchase = build(:purchase, email: "AbC@def.coM")
      purchase.valid?
      expect(purchase.email).to eq("abc@def.com")

      purchase.email = "FOO@BAR.com"
      purchase.save!
      expect(purchase.email).to eq("foo@bar.com")
    end
  end

  describe "charge_card!" do
    it "adds proper error code to purchase if creator's paypal account is restricted and cannot accept payment" do
      allow_any_instance_of(User).to receive(:native_paypal_payment_enabled?).and_return(true)
      paypal_create_order_failure_response = JSON.parse({ status_code: 422,
                                                          result: { name: "UNPROCESSABLE_ENTITY",
                                                                    details: [{
                                                                      field: "/purchase_units/@reference_id=='p0mBFkazbToLRRXTaRgTFw=='/payee",
                                                                      location: "body",
                                                                      issue: "PAYEE_ACCOUNT_RESTRICTED",
                                                                      description: "The merchant account is restricted." }],
                                                                    message: "The requested action could not be performed, semantically incorrect, or failed business validation.",
                                                                    debug_id: "e371fa4eaa124",
                                                                    links: [{
                                                                      href: "https://developer.paypal.com/docs/api/orders/v2/#error-PAYEE_ACCOUNT_RESTRICTED",
                                                                      rel: "information_link",
                                                                      method: "GET" }]
                                                          }
                                                        }.to_json, object_class: OpenStruct)
      allow_any_instance_of(PaypalRestApi).to receive(:create_order).and_return(paypal_create_order_failure_response)

      purchase = create(:purchase, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                   merchant_account: create(:merchant_account_paypal, charge_processor_merchant_id: "CJS32DZ7NDN5L"),
                                   chargeable: create(:native_paypal_chargeable))

      purchase.process!

      expect(purchase.errors.present?).to be(true)
      expect(purchase.errors[:base].first).to eq("There is a problem with creator's paypal account, please try again later (your card was not charged).")
      expect(purchase.stripe_error_code).to eq(PurchaseErrorCode::PAYPAL_MERCHANT_ACCOUNT_RESTRICTED)
    end
  end

  describe "#original_purchase" do
    it "returns the original subscription purchase" do
      original_purchase = create(:membership_purchase, is_archived_original_subscription_purchase: true)
      purchase = create(:purchase, link: original_purchase.link, subscription: original_purchase.subscription, is_original_subscription_purchase: true)
      expect(purchase.reload.original_purchase).to eq(purchase)
    end

    it "returns itself when not a subscription" do
      purchase = create(:purchase)
      expect(purchase.original_purchase).to eq(purchase)
    end

    it "returns itself when it's the original purchase" do
      purchase = create(:membership_purchase)
      expect(purchase.original_purchase).to eq(purchase)
    end
  end

  describe "#true_original_purchase" do
    it "returns the (true) original subscription purchase" do
      original_purchase = create(:membership_purchase, is_archived_original_subscription_purchase: true)
      purchase = create(:purchase, link: original_purchase.link, subscription: original_purchase.subscription, is_original_subscription_purchase: true)
      expect(purchase.reload.true_original_purchase).to eq(original_purchase)
    end

    it "returns itself when not a subscription" do
      purchase = create(:purchase)
      expect(purchase.true_original_purchase).to eq(purchase)
    end

    it "returns itself when it's the original purchase" do
      purchase = create(:membership_purchase)
      expect(purchase.true_original_purchase).to eq(purchase)
    end
  end

  describe "double charge check for the same product on the same IP address with same email" do
    before do
      @product = create(:product)
      @params = { link: @product, ip_address: "1.1.1.1", email: "gumroad@example.com" }
    end

    context "when product doesn't have variants" do
      before do
        create(:purchase, @params)
      end

      it "doesn't create duplicate purchase" do
        expect do
          create(:purchase, @params)
        end.to raise_error(ActiveRecord::RecordInvalid).with_message(/You have already paid for this product. It has been emailed to you./)
      end

      context "after 3 minutes from previous purchase" do
        it "allows to create duplicate purchase" do
          travel_to(3.minutes.from_now) do
            expect do
              create(:purchase, @params)
            end.to change { Purchase.successful.count }.by(1)
          end
        end
      end
    end

    context "when product has variants" do
      before do
        variant_category = create(:variant_category, link: @product)
        @variant1 = create(:variant, variant_category:)
        @variant2 = create(:variant, variant_category:)

        create(:purchase, @params.merge(variant_attributes: [@variant1]))
      end

      it "allows to create purchases when the previously bought product is of a different variant" do
        expect do
          create(:purchase, @params.merge(variant_attributes: [@variant2]))
        end.to change { Purchase.successful.count }.by(1)

        expect do
          create(:purchase, @params.merge(variant_attributes: [@variant1, @variant2]))
        end.to change { Purchase.successful.count }.by(1)
      end

      it "doesn't create duplicate purchase when the previously bought product is of same variant" do
        expect do
          create(:purchase, @params.merge(variant_attributes: [@variant1]))
        end.to raise_error(ActiveRecord::RecordInvalid).with_message(/You have already paid for this product. It has been emailed to you./)
      end

      context "after 3 minutes from previous purchase" do
        it "allows to create duplicate purchase of same variant" do
          travel_to(3.minutes.from_now) do
            expect do
              create(:purchase, @params.merge(variant_attributes: [@variant1]))
            end.to change { Purchase.successful.count }.by(1)
          end
        end
      end
    end
  end

  describe "#charge_processor_unavailable_error" do
    it "returns STRIPE_UNAVAILABLE error if charge_processor_id is nil" do
      purchase = build(:purchase, charge_processor_id: nil)
      expect(purchase.send(:charge_processor_unavailable_error)).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
    end

    it "returns STRIPE_UNAVAILABLE error if charge_processor_id is Stripe" do
      purchase = create(:purchase, charge_processor_id: StripeChargeProcessor.charge_processor_id)
      expect(purchase.send(:charge_processor_unavailable_error)).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
    end

    it "returns PAYPAL_UNAVAILABLE error if charge_processor_id is Paypal" do
      purchase = create(:purchase, charge_processor_id: PaypalChargeProcessor.charge_processor_id)
      expect(purchase.send(:charge_processor_unavailable_error)).to eq PurchaseErrorCode::PAYPAL_UNAVAILABLE
    end

    it "returns PAYPAL_UNAVAILABLE error if charge_processor_id is Braintree" do
      purchase = create(:purchase, charge_processor_id: BraintreeChargeProcessor.charge_processor_id)
      expect(purchase.send(:charge_processor_unavailable_error)).to eq PurchaseErrorCode::PAYPAL_UNAVAILABLE
    end
  end

  describe "#not_charged_and_not_free_trial?" do
    context "with not_charged purchase state" do
      it "returns true for a non-free trial purchase" do
        purchase = build(:purchase, purchase_state: "not_charged")
        expect(purchase.not_charged_and_not_free_trial?).to eq true
      end

      it "returns false for a free trial purchase" do
        purchase = build(:purchase, purchase_state: "not_charged", is_free_trial_purchase: true)
        expect(purchase.not_charged_and_not_free_trial?).to eq false
      end
    end

    context "with other purchase states" do
      it "returns false" do
        ["successful", "failed"].each do |purchase_state|
          purchase = build(:purchase, purchase_state:)
          expect(purchase.not_charged_and_not_free_trial?).to eq false
        end
      end
    end
  end


  describe "#flat_fee_applicable?" do
    before do
      @creator = create(:user, created_at: Date.new(2022, 12, 15))
    end

    it "returns true for regular product purchase" do
      purchase = create(:purchase, link: create(:product, user: @creator))

      expect(purchase.send(:flat_fee_applicable?)).to be true
    end

    it "returns false for original subscription purchase if flat fee is not applicable to the subscription" do
      product = create(:product, user: @creator)
      subscription = create(:subscription, link: product)
      subscription.update!(flat_fee_applicable: false)

      original_purchase = create(:purchase, link: product, subscription:, is_original_subscription_purchase: true)

      expect(original_purchase.send(:flat_fee_applicable?)).to be false
    end

    it "returns true for original subscription purchase if flat fee is applicable to the subscription" do
      product = create(:product, user: @creator)
      subscription = create(:subscription, link: product)

      original_purchase = create(:purchase, link: product, subscription:, is_original_subscription_purchase: true)

      expect(original_purchase.send(:flat_fee_applicable?)).to be true
    end

    it "returns false for recurring charge if flat fee is not applicable to the subscription" do
      product = create(:product, user: @creator)
      subscription = create(:subscription, link: product)
      subscription.update!(flat_fee_applicable: false)

      create(:purchase, link: product, subscription:, is_original_subscription_purchase: true)
      recurring_charge = create(:purchase, link: product, subscription:, is_original_subscription_purchase: false)

      expect(recurring_charge.send(:flat_fee_applicable?)).to be false
    end

    it "returns true for recurring charge if flat fee is applicable to the subscription" do
      product = create(:product, user: @creator)
      subscription = create(:subscription, link: product)

      create(:purchase, link: product, subscription:, is_original_subscription_purchase: true)
      recurring_charge = create(:purchase, link: product, subscription:, is_original_subscription_purchase: false)

      expect(recurring_charge.send(:flat_fee_applicable?)).to be true
    end
  end

  describe "#paypal_refund_expired?" do
    before do
      @paypal_purchase = create(:purchase, created_at: 7.months.ago, card_type: CardType::PAYPAL)
    end

    it "returns true for PayPal purchases that are more than 6 months old" do
      expect(@paypal_purchase.paypal_refund_expired?).to be true
    end

    it "returns false for PayPal purchases that are 6 months old or younger" do
      @paypal_purchase.created_at = 1.months.ago
      expect(@paypal_purchase.paypal_refund_expired?).to be false
    end

    it "returns false for non-PayPal purchases" do
      @paypal_purchase.card_type = nil
      expect(@paypal_purchase.paypal_refund_expired?).to be false
    end
  end

  describe "#refunding_amount_cents" do
    let(:product) { create(:product, user:, price_cents:) }
    let(:purchase) { create(:purchase, link: product, seller: product.user) }

    context "when amount contains .99" do
      let(:price_cents) { 19_99 }

      it "refunds the full amount when argument is a string" do
        expect(purchase.refunding_amount_cents("19.99")).to eq(price_cents)
      end

      it "refunds the full amount when argument is a float" do
        expect(purchase.refunding_amount_cents(19.99)).to eq(price_cents)
      end
    end

    context "when amount is fixed" do
      let(:price_cents) { 10_00 }

      it "refunds the full amount when argument is a string" do
        expect(purchase.refunding_amount_cents("10")).to eq(price_cents)
      end

      it "refunds the full amount when argument is a float" do
        expect(purchase.refunding_amount_cents(10.0)).to eq(price_cents)
      end
    end

    context "when amount is in the thousands" do
      let(:price_cents) { 4000_05 }

      it "refunds the full amount when argument is a string" do
        expect(purchase.refunding_amount_cents("4000.05")).to eq(price_cents)
      end

      it "refunds the full amount when argument is a float" do
        expect(purchase.refunding_amount_cents(4_000.05)).to eq(price_cents)
      end
    end
  end

  describe "#original_offer_code" do
    let(:product) { create(:product, price_cents: 500) }
    let(:offer_code) { create(:offer_code, products: [product], amount_cents: 400) }
    let(:purchase_with_valid_offer_code) { create(:purchase, link: product, offer_code:, price_cents: 900) }

    context "when the offer code was deleted and include_deleted is true" do
      it "uses the cached offer code details" do
        purchase_with_valid_offer_code.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 50, offer_code_is_percent: true, pre_discount_minimum_price_cents: 1800)
        offer_code.mark_deleted!
        expect(purchase_with_valid_offer_code.original_offer_code(include_deleted: true).amount_percentage).to eq 50
      end
    end

    it "returns offer_code if the offer_code is not deleted" do
      expect(purchase_with_valid_offer_code.original_offer_code).to eq offer_code
    end

    it "uses the cached offer code details if present" do
      purchase_with_valid_offer_code.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 50, offer_code_is_percent: true, pre_discount_minimum_price_cents: 1800)
      expect(purchase_with_valid_offer_code.original_offer_code.code).to eq("sxsw")
      expect(purchase_with_valid_offer_code.displayed_price_cents_before_offer_code).to eq 1800
    end

    it "uses the offer code if the purchase is missing cached offer code details" do
      expect(purchase_with_valid_offer_code.displayed_price_cents_before_offer_code).to eq 1300
    end
  end

  describe "#displayed_price_cents_before_offer_code" do
    let(:product) { create(:product, price_cents: 500) }

    it "returns the displayed_price_cents for a purchase with no offer code" do
      purchase = build(:purchase, link: product)
      expect(purchase.displayed_price_cents_before_offer_code).to eq 500
    end

    context "with an offer code" do
      let(:offer_code) { create(:offer_code, products: [product], amount_cents: 300) }
      let(:purchase) { create(:purchase, link: product, offer_code:, price_cents: 900) }

      it "uses the cached offer code details if present" do
        purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 50, offer_code_is_percent: true, pre_discount_minimum_price_cents: 1800)
        expect(purchase.displayed_price_cents_before_offer_code).to eq 1800
      end

      it "uses the offer code if the purchase is missing cached offer code details" do
        expect(purchase.displayed_price_cents_before_offer_code).to eq 1200
      end

      context "when the offer code was deleted and include_deleted is true" do
        it "uses the cached offer code details" do
          offer_code.mark_deleted!
          purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 50, offer_code_is_percent: true, pre_discount_minimum_price_cents: 1800)
          expect(purchase.displayed_price_cents_before_offer_code(include_deleted: true)).to eq 1800
        end
      end

      context "for a 100% off offer code" do
        before do
          offer_code.update!(amount_cents: nil, amount_percentage: 100)
          purchase.update!(displayed_price_cents: 0)
        end

        it "uses the cached offer code details if present" do
          purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: 100, offer_code_is_percent: true, pre_discount_minimum_price_cents: 1800)
          expect(purchase.displayed_price_cents_before_offer_code).to eq 1800
        end

        it "returns nil if the purchase is missing cached offer code details" do
          expect(purchase.displayed_price_cents_before_offer_code).to eq nil
        end
      end
    end
  end

  describe "associations" do
    let(:circle_integration) { create(:circle_integration) }
    let(:discord_integration) { create(:discord_integration) }
    let(:purchase) { create(:purchase, link: create(:product, active_integrations: [circle_integration, discord_integration])) }
    let!(:circle_purchase_integration) { create(:purchase_integration, integration: circle_integration, purchase:) }
    let!(:discord_purchase_integration) { create(:discord_purchase_integration, integration: discord_integration, purchase:) }

    context "has many `purchase_integrations`" do
      it "returns alive and deleted purchase_integrations" do
        expect do
          circle_purchase_integration.mark_deleted!
        end.to change { purchase.purchase_integrations.count }.by(0)
        expect(purchase.purchase_integrations.pluck(:integration_id)).to match_array [circle_integration, discord_integration].map(&:id)
      end
    end

    context "has many `live_purchase_integrations`" do
      it "does not return deleted purchase_integrations" do
        expect do
          discord_purchase_integration.mark_deleted!
        end.to change { purchase.live_purchase_integrations.count }.by(-1)
        expect(purchase.live_purchase_integrations.pluck(:integration_id)).to match_array [circle_integration.id]
      end
    end

    context "has many `active_integrations`" do
      it "does not return deleted integrations" do
        expect do
          circle_purchase_integration.mark_deleted!
        end.to change { purchase.active_integrations.count }.by(-1)
        expect(purchase.active_integrations.pluck(:integration_id)).to match_array [discord_integration.id]
      end
    end

    it { is_expected.to have_one(:utm_link_driven_sale) }
    it { is_expected.to have_one(:utm_link).through(:utm_link_driven_sale) }
  end

  describe "#transcode_product_videos" do
    before do
      @product = create(:product_with_video_file)
      @product.product_files.first.update_attribute(:analyze_completed, true)
      @purchase = create(:purchase_in_progress, link: @product)
    end

    context "when product.transcode_videos_on_purchase is disabled" do
      before do
        @product.transcode_videos_on_purchase = false
        @product.save!
      end

      it "doesn't transcode videos on purchase" do
        @purchase.mark_successful!

        expect(TranscodeVideoForStreamingWorker.jobs.size).to eq(0)
      end
    end

    context "when product.transcode_videos_on_purchase is enabled" do
      before do
        @product.enable_transcode_videos_on_purchase!
      end

      it "transcodes videos and sets product.transcode_videos_on_purchase to false" do
        @purchase.mark_successful!
        product_file = @product.product_files.first

        expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(product_file.id, product_file.class.name)
        expect(@product.reload.transcode_videos_on_purchase?).to eq false
      end
    end
  end

  describe "#formatted_affiliate_credit_amount" do
    before { allow_any_instance_of(Purchase).to receive(:get_rate).and_return("0.8") }

    it "returns the formatted affiliate credit amount in USD" do
      purchase = create(:purchase, price_cents: 20_00,
                                   affiliate: create(:direct_affiliate, affiliate_basis_points: 5000),
                                   displayed_price_currency_type: "gbp")

      expect(purchase.formatted_affiliate_credit_amount).to eq("$10.81") # (20 EUR / 0.8 EUR/USD) * 0.5 cut - 1.69 (half of the fee) = $10.81
    end
  end

  describe "#format_price_in_currency" do
    before { allow_any_instance_of(Purchase).to receive(:rate_converted_to_usd).and_return(0.5) }

    it "formats the amount in the purchase's currency" do
      purchase = create(:purchase)
      expect(purchase.format_price_in_currency(5_50)).to eq "$5.50"

      purchase.displayed_price_currency_type = "gbp"
      expect(purchase.format_price_in_currency(5_50)).to eq "£2.75"
    end

    it "formats the amount for a subscription purchase in the purchase's currency" do
      purchase = create(:membership_purchase)
      expect(purchase.format_price_in_currency(5_50)).to eq "$5.50 a month"

      purchase.displayed_price_currency_type = "eur"
      expect(purchase.format_price_in_currency(5_50)).to eq "€2.75 a month"
    end
  end

  describe "#enqueue_update_sales_related_products_infos_job" do
    let(:product) { create(:product) }

    context "when the product stats has been backfilled" do
      it "enqueues UpdateSalesRelatedProductsInfosJob upon purchase success" do
        purchase = create(:purchase_with_balance, link: product)
        expect(UpdateSalesRelatedProductsInfosJob).to have_enqueued_sidekiq_job(purchase.id, true)
      end
    end
  end

  describe "#free_purchase?" do
    let(:purchase) { create(:free_purchase, shipping_cents: 0) }

    it "returns true" do
      expect(purchase.free_purchase?).to eq true
    end

    context "when there is a shipping fee" do
      let(:purchase) { create(:free_purchase, shipping_cents: 100) }

      it "returns false" do
        expect(purchase.free_purchase?).to eq false
      end
    end

    context "when there is a price" do
      let(:purchase) { create(:purchase) }

      it "returns false" do
        expect(purchase.free_purchase?).to eq false
      end
    end
  end

  context "AudienceMember" do
    describe "#should_be_audience_member?" do
      it "only returns true for expected cases" do
        purchase = create(:purchase)
        expect(purchase.should_be_audience_member?).to eq(true)

        [
          create(:failed_purchase),
          create(:refunded_purchase),
          create(:test_purchase),
          create(:purchase, can_contact: false),
          create(:disputed_purchase),
          create(:purchase, is_gift_sender_purchase: true),
        ].each do |purchase|
          expect(purchase.should_be_audience_member?).to eq(false)
        end

        purchase = create(:purchase, chargeback_date: Time.current, chargeback_reversed: true)
        expect(purchase.should_be_audience_member?).to eq(true)

        purchase = create(:free_trial_membership_purchase)
        expect(purchase.should_be_audience_member?).to eq(true)

        purchase = create(:membership_purchase)
        subscription = purchase.subscription
        expect(purchase.should_be_audience_member?).to eq(true)

        # Even if the original purchase was refunded, or charged back, active subscriptions are still valid
        purchase.update!(stripe_refunded: true)
        expect(purchase.should_be_audience_member?).to eq(true)
        purchase.update!(chargeback_date: Time.current)
        expect(purchase.should_be_audience_member?).to eq(true)

        subscription.deactivate!
        expect(purchase.reload.should_be_audience_member?).to eq(false)

        subscription.resubscribe!
        purchase.update!(is_original_subscription_purchase: false)
        expect(purchase.reload.should_be_audience_member?).to eq(false)

        purchase.update!(is_original_subscription_purchase: true)
        subscription.update!(is_test_subscription: true)
        expect(purchase.reload.should_be_audience_member?).to eq(false)

        subscription.update!(is_test_subscription: false)
        purchase.update!(is_archived_original_subscription_purchase: true)
        expect(purchase.reload.should_be_audience_member?).to eq(false)
        purchase.update!(is_archived_original_subscription_purchase: false)

        purchase.update_column(:email, nil)
        expect(purchase.should_be_audience_member?).to eq(false)
        purchase.update_column(:email, "some-invalid-email")
        expect(purchase.should_be_audience_member?).to eq(false)
      end
    end

    it "adds member when successful" do
      purchase = create(:purchase_in_progress)

      expect(AudienceMember.find_by(email: purchase.email, seller: purchase.seller)).to be_nil

      expect do
        purchase.update_balance_and_mark_successful!
      end.to change(AudienceMember, :count).by(1)

      member = AudienceMember.find_by(email: purchase.email, seller: purchase.seller)
      expect(member.details["purchases"].size).to eq(1)
      expect(member.details["purchases"].first).to eq(purchase.audience_member_details.stringify_keys)

      create(:purchase, :from_seller, seller: purchase.seller, email: purchase.email)
      member.reload
      expect(member.details["purchases"].size).to eq(2)
    end

    it "removes member when uncontactable" do
      purchase = create(:purchase)
      create(:active_follower, user: purchase.seller, email: purchase.email)
      expect do
        purchase.update!(can_contact: false)
      end.not_to change(AudienceMember, :count)

      member = AudienceMember.find_by(email: purchase.email, seller: purchase.seller)
      expect(member.details["follower"]).to be_present
      expect(member.details["purchases"]).to be_nil
    end

    it "removes member when uncontactable with no other audience types" do
      purchase = create(:purchase)
      expect do
        purchase.update!(can_contact: false)
      end.to change(AudienceMember, :count).by(-1)

      member = AudienceMember.find_by(email: purchase.email, seller: purchase.seller)
      expect(member).to be_nil
    end

    it "removes member when subscription is deactivated" do
      purchase = create(:membership_purchase)

      expect do
        purchase.subscription.deactivate!
      end.to change(AudienceMember, :count).by(-1)

      expect do
        purchase.subscription.resubscribe!
      end.to change(AudienceMember, :count).by(1)
    end

    it "recreates member when changing email" do
      purchase = create(:purchase)
      old_email = purchase.email
      new_email = "new@example.com"
      purchase.update!(email: new_email)

      old_member = AudienceMember.find_by(email: old_email, seller: purchase.seller)
      new_member = AudienceMember.find_by(email: new_email, seller: purchase.seller)
      expect(old_member).to be_nil
      expect(new_member).to be_present
    end
  end

  describe "purchasing power parity validations" do
    context "when the card country doesn't match the IP country" do
      let(:purchase) { create(:purchase, is_purchasing_power_parity_discounted: true, card_country: "US", ip_country: "CA", credit_card: create(:credit_card)) }

      it "adds an error" do
        purchase.prepare_for_charge!
        expect(purchase.error_code).to eq(PurchaseErrorCode::PPP_CARD_COUNTRY_NOT_MATCHING)
        expect(purchase.errors.full_messages.first).to eq("In order to apply a purchasing power parity discount, you must use a card issued in the country you are in. Please try again with a local card, or remove the discount during checkout.")
      end

      context "when the seller has payment method verification disabled" do
        before do
          purchase.seller.update(purchasing_power_parity_payment_verification_disabled: true)
        end

        it "doesn't add an error" do
          purchase.prepare_for_charge!
          expect(purchase.error_code).to be_nil
          expect(purchase.errors).to be_empty
        end
      end
    end
  end

  describe "#prepare_merchant_account" do
    it "adds an error if merchant account is a Brazilian Stripe Connect account and purchase has an affiliate" do
      seller = create(:named_seller, check_merchant_account_is_linked: true)
      product = create(:product, price_cents: 20_00, user: seller)
      purchase = build(:purchase,
                       link: product,
                       chargeable: create(:chargeable),
                       affiliate: create(:direct_affiliate, affiliate_basis_points: 5000),
                       merchant_account: create(:merchant_account_stripe_connect, user: seller, country: "BR"))

      purchase.send(:prepare_merchant_account, StripeChargeProcessor.charge_processor_id)

      expect(purchase.errors[:base].present?).to be(true)
      expect(purchase.error_code).to eq PurchaseErrorCode::BRAZILIAN_MERCHANT_ACCOUNT_WITH_AFFILIATE
      expect(purchase.errors.full_messages.first).to eq("Affiliate sales are not currently supported for this product.")
    end
  end

  describe "#giftee_name_or_email" do
    let(:purchase) { create(:purchase) }

    context "for a non-gift purchase" do
      it "returns nil" do
        expect(purchase.giftee_name_or_email).to be_nil
      end
    end

    context "when the gift email is not hidden" do
      let(:gift) { create(:gift, giftee_email: "giftee@example.com", giftee_purchase: purchase) }

      before { purchase.update!(is_gift_receiver_purchase: true, gift_received: gift) }

      it "returns the gift email" do
        expect(purchase.giftee_name_or_email).to eq "giftee@example.com"
      end
    end

    context "when the gift email is hidden" do
      context "for a gifter purchase" do
        let(:giftee_purchase) { create(:purchase, purchaser: create(:user, name: "Gift User")) }
        let(:gift) { create(:gift, is_recipient_hidden: true, gifter_purchase: purchase, giftee_purchase:) }

        before { purchase.update!(is_gift_sender_purchase: true, gift_given: gift) }

        it "returns the giftee's name" do
          expect(purchase.giftee_name_or_email).to eq "Gift User"
        end
      end

      context "for a giftee purchase" do
        let(:gift) { create(:gift, is_recipient_hidden: true, giftee_purchase: purchase) }

        before { purchase.update!(is_gift_receiver_purchase: true, gift_received: gift, purchaser: create(:user, name: "Gift User")) }

        it "returns the giftee's name" do
          expect(purchase.giftee_name_or_email).to eq "Gift User"
        end
      end

      context "when the user has not set a name" do
        let(:gift) { create(:gift, is_recipient_hidden: true, giftee_purchase: purchase) }

        before { purchase.update!(is_gift_receiver_purchase: true, gift_received: gift, purchaser: create(:user, username: "giftuser")) }

        it "falls back to the username" do
          expect(purchase.giftee_name_or_email).to eq "giftuser"
        end
      end
    end
  end

  describe "#json_data_for_mobile" do
    before do
      @seller = create(:user, purchasing_power_parity_enabled: true)
      @seller.update!(refund_fee_notice_shown: false)
      @product = create(:physical_product, user: @seller, content_updated_at: Time.current)
      create(:variant_category, link: @product, title: "Color")
      create(:variant_category, link: @product, title: "Size")
      @large_blue_sku = create(:sku, link: @product, name: "Blue - large", custom_sku: "large_blue")
      @purchaser = create(:user)
      @offer_code = create(:offer_code,
                           code: "DISCOUNT10",
                           amount_cents: 1000,
                        )
      @purchase = create(:physical_purchase, link: @product, variant_attributes: [@large_blue_sku],
                                             is_purchasing_power_parity_discounted: true, ip_country: "Latvia", purchaser: @purchaser, offer_code: @offer_code,
                                             affiliate: create(:direct_affiliate, affiliate_basis_points: 500), price_cents: 2000, stripe_refunded: false, stripe_partially_refunded: false)
      @purchase.create_purchasing_power_parity_info(factor: 0.49)
      @review = create(:product_review, purchase: @purchase, rating: 5)
      @upsell = create(:upsell, product: @product, seller: @seller)
      @shipment = create(:shipment, purchase: @purchase, ship_state: :shipped, tracking_url: "https://shipping.example.com/1234", shipped_at: Time.current)
    end

    it "returns purchase information" do
      json_data = @purchase.link.as_json(mobile: true)
      json_data.merge!(
        {
          purchase_id: @purchase.external_id,
          purchased_at: @purchase.created_at,
          product_updates_data: @purchase.update_json_data_for_mobile,
          user_id: @purchaser.external_id,
          is_archived: @purchase.is_archived,
          content_updated_at: @purchase.link.content_updated_at,
          custom_delivery_url: nil, # Deprecated
          purchase_email: @purchase.email,
          variants: {
            "Color - Size" => {
              is_sku: true,
              title: "Color - Size",
              selected_variant: {
                id: @large_blue_sku.external_id,
                name: @large_blue_sku.name,
              }
            }
          },
          amount_refundable_in_currency: @purchase.amount_refundable_in_currency,
          currency_symbol: "$",
          refund_fee_notice_shown: false,
          product_rating: @review.rating,
          refunded: false,
          partially_refunded: false,
          chargedback: false,
          full_name: "barnabas",
          sku_id: @large_blue_sku.custom_sku,
          sku_external_id: @large_blue_sku.external_id,
          quantity: @purchase.quantity,
          order_id: @purchase.external_id_numeric,
          shipped: true,
          tracking_url: @shipment.calculated_tracking_url,
          shipping_address: {
            full_name: "barnabas",
            street_address: "123 barnabas street",
            city: "barnabasville",
            state: "CA",
            zip_code: "94114",
            country: "United States"
          },
          ppp: {
            country: "Latvia",
            discount: "51%"
          },
          offer_code: {
            code: "DISCOUNT10",
            displayed_amount_off: "$10",
          },
          affiliate: {
            amount: "$0.83",
            email: @purchase.affiliate.affiliate_user.form_email,
          }
        }
      )
      expect(@purchase.json_data_for_mobile(include_sale_details: true)).to eq(json_data)
    end
  end

  describe "price validation" do
    context "purchase is a bundle product purchase" do
      let(:purchase) { create(:purchase, is_bundle_product_purchase: true, price_cents: 0) }

      it "doesn't add an error when the price is 0 for a non-free product" do
        expect(purchase.errors).to be_empty
      end
    end
  end

  describe "#display_referrer" do
    let!(:purchase) { create(:purchase) }

    context "library purchase" do
      before { purchase.update!(recommended_by: RecommendationType::GUMROAD_LIBRARY_RECOMMENDATION) }

      it "returns the correct referrer" do
        expect(purchase.display_referrer).to eq("Gumroad Library")
      end
    end

    context "discover purchase" do
      before { purchase.update!(was_product_recommended: true) }

      it "returns the correct referrer" do
        expect(purchase.display_referrer).to eq("Gumroad Discover")
      end
    end

    context "direct purchase" do
      before { purchase.update!(referrer: "direct") }

      it "returns the correct referrer" do
        expect(purchase.display_referrer).to eq("Direct")
      end
    end

    context "profile purchase" do
      before { purchase.update!(referrer: "https://#{purchase.seller.username}.gumroad.com") }

      it "returns the correct referrer" do
        expect(purchase.display_referrer).to eq("Profile")
      end
    end

    context "common referrer purchase" do
      before { purchase.update!(referrer: "https://facebook.com") }

      it "returns the correct referrer" do
        expect(purchase.display_referrer).to eq("Facebook")
      end
    end

    context "normal referrer purchase" do
      before { purchase.update!(referrer: "https://normal.com") }

      it "returns the correct referrer" do
        expect(purchase.display_referrer).to eq("normal.com")
      end
    end

    context "receipt recommendation" do
      before do
        purchase.update!(
          was_product_recommended: true,
          recommended_by: RecommendationType::GUMROAD_RECEIPT_RECOMMENDATION
        )
      end

      it "returns 'Gumroad receipt'" do
        expect(purchase.display_referrer).to eq("Gumroad Receipt")
      end
    end

    context "product page recommendation" do
      before do
        purchase.update!(
          was_product_recommended: true,
          recommended_by: RecommendationType::PRODUCT_RECOMMENDATION
        )
      end

      it "returns 'Gumroad product page'" do
        expect(purchase.display_referrer).to eq("Gumroad Product Page")
      end
    end

    context "wishlist recommendation" do
      before do
        purchase.update!(
          was_product_recommended: true,
          recommended_by: RecommendationType::WISHLIST_RECOMMENDATION
        )
      end

      it "returns 'Gumroad wishlist'" do
        expect(purchase.display_referrer).to eq("Gumroad Wishlist")
      end
    end

    context "unknown recommendation type" do
      before do
        purchase.update!(
          was_product_recommended: true,
          recommended_by: "unknown_recommendation_type"
        )
      end
    end

    context "more like this recommendation" do
      before do
        purchase.update!(
          was_product_recommended: true,
          recommended_by: RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION
        )
      end

      it "returns 'Gumroad product recommendations'" do
        expect(purchase.display_referrer).to eq("Gumroad Product Recommendations")
      end
    end
  end

  describe "#ppp_info" do
    let(:purchase) { create(:purchase, ip_country: "United States") }

    context "PPP-discounted purchase" do
      before do
        purchase.update!(is_purchasing_power_parity_discounted: true)
        purchase.create_purchasing_power_parity_info!(factor: 0.5)
      end

      it "returns the PPP info" do
        expect(purchase.ppp_info).to eq(
          {
            country: "United States",
            discount: "50%",
          }
        )
      end
    end

    context "non-PPP-discounted purchase" do
      it "returns nil" do
        expect(purchase.ppp_info).to be_nil
      end
    end
  end

  describe "#linked_license" do
    it "returns the linked license" do
      purchase = create(:purchase, license: create(:license), link: create(:product, is_licensed: true))
      expect(purchase.linked_license).to eq(purchase.license)
    end

    context "gift purchase" do
      let(:gifter_purchase) { create(:purchase, is_gift_sender_purchase: true) }
      let(:giftee_purchase) { create(:purchase, is_gift_receiver_purchase: true, license: create(:license), link: create(:product, is_licensed: true)) }
      let!(:gift) { create(:gift, gifter_purchase:, giftee_purchase:) }

      it "returns the giftee's license" do
        expect(gifter_purchase.reload.linked_license).to eq(giftee_purchase.license)
      end
    end

    context "no license" do
      let(:purchase) { create(:purchase) }
      it "returns nil" do
        expect(purchase.linked_license).to be_nil
      end
    end
  end

  describe "#build_flow_of_funds_from_combined_charge", :vcr do
    before do
      charge = create(:charge, amount_cents: 100_00, gumroad_amount_cents: 10_00)

      @purchase1 = create(:purchase, total_transaction_cents: 20_00)
      @purchase1.update!(fee_cents: 2_00)
      @purchase2 = create(:purchase, total_transaction_cents: 30_00)
      @purchase2.update!(fee_cents: 3_00)
      @purchase3 = create(:purchase, total_transaction_cents: 50_00)
      @purchase3.update!(fee_cents: 5_00)

      charge.purchases << @purchase1
      charge.purchases << @purchase2
      charge.purchases << @purchase3
    end

    it "returns a flow of funds object for the purchase with proper amounts based on purchase's portion in the charge" do
      combined_flow_of_funds = FlowOfFunds.new(
        issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100_00),
        settled_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 125_00),
        gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 10_00),
        merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 125_00),
        merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 112_50)
      )

      flow_of_funds = @purchase1.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)

      expect(flow_of_funds.issued_amount.cents).to eq(20_00)
      expect(flow_of_funds.issued_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.settled_amount.cents).to eq(25_00)
      expect(flow_of_funds.settled_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.gumroad_amount.cents).to eq(2_00)
      expect(flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.merchant_account_gross_amount.cents).to eq(25_00)
      expect(flow_of_funds.merchant_account_gross_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.merchant_account_net_amount.cents).to eq(22_50)
      expect(flow_of_funds.merchant_account_net_amount.currency).to eq(Currency::CAD)

      flow_of_funds = @purchase2.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)

      expect(flow_of_funds.issued_amount.cents).to eq(30_00)
      expect(flow_of_funds.issued_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.settled_amount.cents).to eq(37_50)
      expect(flow_of_funds.settled_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.gumroad_amount.cents).to eq(3_00)
      expect(flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.merchant_account_gross_amount.cents).to eq(37_50)
      expect(flow_of_funds.merchant_account_gross_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.merchant_account_net_amount.cents).to eq(33_75)
      expect(flow_of_funds.merchant_account_net_amount.currency).to eq(Currency::CAD)

      flow_of_funds = @purchase3.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)

      expect(flow_of_funds.issued_amount.cents).to eq(50_00)
      expect(flow_of_funds.issued_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.settled_amount.cents).to eq(62_50)
      expect(flow_of_funds.settled_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.gumroad_amount.cents).to eq(5_00)
      expect(flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.merchant_account_gross_amount.cents).to eq(62_50)
      expect(flow_of_funds.merchant_account_gross_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.merchant_account_net_amount.cents).to eq(56_25)
      expect(flow_of_funds.merchant_account_net_amount.currency).to eq(Currency::CAD)
    end

    it "returns a proper amounts based on purchase's portion in the charge when combined flow of funds has negative amounts" do
      combined_flow_of_funds = FlowOfFunds.new(
        issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -100_00),
        settled_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -125_00),
        gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -10_00),
        merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -125_00),
        merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -112_50)
      )

      flow_of_funds = @purchase1.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)

      expect(flow_of_funds.issued_amount.cents).to eq(-20_00)
      expect(flow_of_funds.issued_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.settled_amount.cents).to eq(-25_00)
      expect(flow_of_funds.settled_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.gumroad_amount.cents).to eq(-2_00)
      expect(flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.merchant_account_gross_amount.cents).to eq(-25_00)
      expect(flow_of_funds.merchant_account_gross_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.merchant_account_net_amount.cents).to eq(-22_50)
      expect(flow_of_funds.merchant_account_net_amount.currency).to eq(Currency::CAD)

      flow_of_funds = @purchase2.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)

      expect(flow_of_funds.issued_amount.cents).to eq(-30_00)
      expect(flow_of_funds.issued_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.settled_amount.cents).to eq(-37_50)
      expect(flow_of_funds.settled_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.gumroad_amount.cents).to eq(-3_00)
      expect(flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.merchant_account_gross_amount.cents).to eq(-37_50)
      expect(flow_of_funds.merchant_account_gross_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.merchant_account_net_amount.cents).to eq(-33_75)
      expect(flow_of_funds.merchant_account_net_amount.currency).to eq(Currency::CAD)

      flow_of_funds = @purchase3.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)

      expect(flow_of_funds.issued_amount.cents).to eq(-50_00)
      expect(flow_of_funds.issued_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.settled_amount.cents).to eq(-62_50)
      expect(flow_of_funds.settled_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.gumroad_amount.cents).to eq(-5_00)
      expect(flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.merchant_account_gross_amount.cents).to eq(-62_50)
      expect(flow_of_funds.merchant_account_gross_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.merchant_account_net_amount.cents).to eq(-56_25)
      expect(flow_of_funds.merchant_account_net_amount.currency).to eq(Currency::CAD)
    end

    it "returns proper amounts based on purchase's portion in the charge when some purchases have affiliate fees" do
      combined_flow_of_funds = FlowOfFunds.new(
          issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -100_00),
          settled_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -125_00),
          gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -36_00),
          merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -125_00),
          merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -80_00)
      )

      @purchase1.update!(affiliate_credit_cents: 6_00)
      @purchase3.update!(affiliate_credit_cents: 20_00)
      @purchase1.charge.update!(gumroad_amount_cents: 36_00)

      flow_of_funds = @purchase1.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)

      expect(flow_of_funds.issued_amount.cents).to eq(-20_00)
      expect(flow_of_funds.issued_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.settled_amount.cents).to eq(-25_00)
      expect(flow_of_funds.settled_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.gumroad_amount.cents).to eq(-8_00)
      expect(flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.merchant_account_gross_amount.cents).to eq(-23_44)
      expect(flow_of_funds.merchant_account_gross_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.merchant_account_net_amount.cents).to eq(-15_00)
      expect(flow_of_funds.merchant_account_net_amount.currency).to eq(Currency::CAD)

      flow_of_funds = @purchase2.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)

      expect(flow_of_funds.issued_amount.cents).to eq(-30_00)
      expect(flow_of_funds.issued_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.settled_amount.cents).to eq(-37_50)
      expect(flow_of_funds.settled_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.gumroad_amount.cents).to eq(-3_00)
      expect(flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.merchant_account_gross_amount.cents).to eq(-52_74)
      expect(flow_of_funds.merchant_account_gross_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.merchant_account_net_amount.cents).to eq(-33_75)
      expect(flow_of_funds.merchant_account_net_amount.currency).to eq(Currency::CAD)

      flow_of_funds = @purchase3.build_flow_of_funds_from_combined_charge(combined_flow_of_funds)

      expect(flow_of_funds.issued_amount.cents).to eq(-50_00)
      expect(flow_of_funds.issued_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.settled_amount.cents).to eq(-62_50)
      expect(flow_of_funds.settled_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.gumroad_amount.cents).to eq(-25_00)
      expect(flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.merchant_account_gross_amount.cents).to eq(-48_83)
      expect(flow_of_funds.merchant_account_gross_amount.currency).to eq(Currency::CAD)
      expect(flow_of_funds.merchant_account_net_amount.cents).to eq(-31_25)
      expect(flow_of_funds.merchant_account_net_amount.currency).to eq(Currency::CAD)
    end
  end

  describe "#mandate_options_for_stripe" do
    it "returns nil for PayPal and Braintree purchases" do
      product = create(:membership_product)
      subscription = create(:subscription, link: product)
      expect(create(:purchase, charge_processor_id: PaypalChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress",
                               card_country: "IN", subscription:, is_original_subscription_purchase: true, chargeable: create(:native_paypal_chargeable)).mandate_options_for_stripe).to be nil
      expect(create(:purchase, charge_processor_id: BraintreeChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress",
                               card_country: "IN", subscription:, is_original_subscription_purchase: true, chargeable: create(:paypal_chargeable)).mandate_options_for_stripe).to be nil
    end

    it "returns nil for Stripe purchases if card country is not India" do
      product = create(:membership_product)
      subscription = create(:subscription, link: product)
      expect(create(:purchase, charge_processor_id: StripeChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress",
                               card_country: "US", subscription:, is_original_subscription_purchase: true, chargeable: create(:chargeable)).mandate_options_for_stripe).to be nil
    end

    it "returns nil for a multi buy purchase" do
      allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:country).and_return("IN")

      product = create(:membership_product)
      subscription = create(:subscription, link: product)
      expect(create(:purchase, charge_processor_id: StripeChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress", subscription:,
                               card_country: "IN", is_original_subscription_purchase: true, is_multi_buy: true, chargeable: create(:chargeable)).mandate_options_for_stripe).to be nil
    end

    it "returns nil for purchases that do not require future off-session charges" do
      allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:country).and_return("IN")

      product = create(:product)
      expect(create(:purchase, link: product, purchase_state: "in_progress",
                               charge_processor_id: StripeChargeProcessor.charge_processor_id, card_country: "IN", chargeable: create(:chargeable)).mandate_options_for_stripe).to be nil
    end

    it "returns correct parameter to create a mandate on Stripe for purchases that require off-session charges" do
      allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:country).and_return("IN")

      product = create(:membership_product)
      subscription = create(:subscription, link: product)

      mandate_options = create(:purchase, charge_processor_id: StripeChargeProcessor.charge_processor_id, link: product, purchase_state: "in_progress",
                                          card_country: "IN", subscription:, is_original_subscription_purchase: true, chargeable: create(:chargeable)).mandate_options_for_stripe

      expect(mandate_options).to be_present
      expect(mandate_options[:payment_method_options][:card][:mandate_options][:amount_type]).to eq("maximum")
    end
  end

  describe "#is_an_off_session_charge_on_indian_card?" do
    context "when card country is not India" do
      it "returns false if it is a regular purchase" do
        expect(create(:purchase_in_progress).is_an_off_session_charge_on_indian_card?).to be false
      end

      it "returns false if it is a membership purchase" do
        membership_purchase = create(:purchase_in_progress, link: create(:membership_product))

        expect(membership_purchase.is_an_off_session_charge_on_indian_card?).to be false
      end

      it "returns false if it is a recurring charge and charge processor is not Stripe" do
        product = create(:subscription_product)
        subscription = create(:subscription, link: product)
        create(:purchase, subscription:, is_original_subscription_purchase: true)
        recurring_charge = create(:purchase_in_progress, is_original_subscription_purchase: false,
                                                         link: product, subscription:, charge_processor_id: PaypalChargeProcessor.charge_processor_id)

        expect(recurring_charge.is_an_off_session_charge_on_indian_card?).to be false
      end

      it "returns false if it is a preorder charge and charge processor is not Stripe" do
        product = create(:product, is_in_preorder_state: true)
        preorder_link = create(:preorder_link, link: product)
        authorization_purchase = create(:preorder_authorization_purchase, link: product)
        preorder = preorder_link.build_preorder(authorization_purchase)

        preorder_charge = create(:purchase_in_progress, link: product, preorder:,
                                                        charge_processor_id: PaypalChargeProcessor.charge_processor_id)

        expect(preorder_charge.is_an_off_session_charge_on_indian_card?).to be false
      end

      it "returns false if it is a recurring charge and charge processor is Stripe" do
        product = create(:subscription_product)
        subscription = create(:subscription, link: product)
        create(:purchase, subscription:, is_original_subscription_purchase: true)
        recurring_charge = create(:purchase_in_progress, is_original_subscription_purchase: false, link: product, subscription:)

        expect(recurring_charge.is_an_off_session_charge_on_indian_card?).to be false
      end

      it "returns false if it is a preorder charge and charge processor is Stripe" do
        product = create(:product, is_in_preorder_state: true)
        preorder_link = create(:preorder_link, link: product)
        authorization_purchase = create(:preorder_authorization_purchase, link: product)
        preorder = preorder_link.build_preorder(authorization_purchase)

        preorder_charge = create(:purchase_in_progress, link: product, preorder:)

        expect(preorder_charge.is_an_off_session_charge_on_indian_card?).to be false
      end
    end

    context "when card country is India" do
      it "returns false if it is a regular purchase" do
        expect(create(:purchase_in_progress, card_country: "IN").is_an_off_session_charge_on_indian_card?).to be false
      end

      it "returns false if it is a membership purchase" do
        membership_purchase = create(:purchase_in_progress, card_country: "IN", link: create(:membership_product))

        expect(membership_purchase.is_an_off_session_charge_on_indian_card?).to be false
      end

      it "returns false if it is a recurring charge and charge processor is not Stripe" do
        product = create(:subscription_product)
        subscription = create(:subscription, link: product)
        create(:purchase, subscription:, is_original_subscription_purchase: true)
        recurring_charge = create(:purchase_in_progress, is_original_subscription_purchase: false, link: product, card_country: "IN",
                                                         subscription:, charge_processor_id: PaypalChargeProcessor.charge_processor_id)

        expect(recurring_charge.is_an_off_session_charge_on_indian_card?).to be false
      end

      it "returns false if it is a preorder charge but charge processor is not Stripe" do
        product = create(:product, is_in_preorder_state: true)
        preorder_link = create(:preorder_link, link: product)
        authorization_purchase = create(:preorder_authorization_purchase, link: product)
        preorder = preorder_link.build_preorder(authorization_purchase)

        preorder_charge = create(:purchase_in_progress, link: product, preorder:, card_country: "IN",
                                                        charge_processor_id: PaypalChargeProcessor.charge_processor_id)

        expect(preorder_charge.is_an_off_session_charge_on_indian_card?).to be false
      end

      it "returns true if it is a recurring charge" do
        product = create(:subscription_product)
        subscription = create(:subscription, link: product)
        create(:purchase, subscription:, is_original_subscription_purchase: true)
        recurring_charge = create(:purchase_in_progress, is_original_subscription_purchase: false, card_country: "IN", link: product, subscription:)

        expect(recurring_charge.is_an_off_session_charge_on_indian_card?).to be true
      end

      it "returns true if it is a preorder charge" do
        product = create(:product, is_in_preorder_state: true)
        preorder_link = create(:preorder_link, link: product)
        authorization_purchase = create(:preorder_authorization_purchase, link: product)
        preorder = preorder_link.build_preorder(authorization_purchase)

        preorder_charge = create(:purchase_in_progress, link: product, preorder:, card_country: "IN")

        expect(preorder_charge.is_an_off_session_charge_on_indian_card?).to be true
      end
    end
  end

  describe "#can_force_update?" do
    it "returns true if purchase is in progress and is not an off session charge on Indian card" do
      expect(create(:purchase_in_progress).can_force_update?).to be true
    end

    it "returns false if purchase is not in progress" do
      expect(create(:purchase, purchase_state: "successful").can_force_update?).to be false
      expect(create(:purchase, purchase_state: "failed").can_force_update?).to be false
    end

    it "returns true if an off session charge on Indian card is in progress and was not created in the last 26 hours" do
      allow_any_instance_of(Purchase).to receive(:is_an_off_session_charge_on_indian_card?).and_return true

      expect(create(:purchase_in_progress, created_at: 27.hours.ago).can_force_update?).to be true
    end

    it "returns false if an off session charge on Indian card is in progress and was created in the last 26 hours" do
      allow_any_instance_of(Purchase).to receive(:is_an_off_session_charge_on_indian_card?).and_return true

      expect(create(:purchase_in_progress, created_at: 10.hours.ago).can_force_update?).to be false
    end

    it "returns false if an off session charge on Indian card is not in progress" do
      allow_any_instance_of(Purchase).to receive(:is_an_off_session_charge_on_indian_card?).and_return true

      expect(create(:purchase, purchase_state: "failed", created_at: 27.hours.ago).can_force_update?).to be false
    end
  end

  describe "#save_charge_data" do
    it "saves all charge related info from the given charge on the purchase" do
      stripe_charge = ChargeProcessor.get_charge(StripeChargeProcessor.charge_processor_id, "ch_2OTlIf9e1RjUNIyY1adIdtGp")

      purchase = create(:purchase_in_progress, charge_processor_id: nil, stripe_transaction_id: nil,
                                               processor_fee_cents_currency: nil, stripe_fingerprint: nil, stripe_card_id: nil,
                                               card_expiry_month: nil, card_expiry_year: nil, flow_of_funds: nil)
      expect(purchase.charge_processor_id).to be nil
      expect(purchase.stripe_refunded).to be nil
      expect(purchase.stripe_transaction_id).to be nil
      expect(purchase.processor_fee_cents).to be nil
      expect(purchase.processor_fee_cents_currency).to be nil
      expect(purchase.stripe_fingerprint).to be nil
      expect(purchase.stripe_card_id).to be nil
      expect(purchase.card_expiry_month).to be nil
      expect(purchase.card_expiry_year).to be nil
      expect(purchase.was_zipcode_check_performed).to be false
      expect(purchase.flow_of_funds).to be nil

      purchase.save_charge_data(stripe_charge)

      expect(purchase.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
      expect(purchase.stripe_refunded).to be true
      expect(purchase.stripe_transaction_id).to eq(stripe_charge.id)
      expect(purchase.processor_fee_cents).to eq(stripe_charge.fee)
      expect(purchase.processor_fee_cents_currency).to eq(stripe_charge.fee_currency)
      expect(purchase.stripe_fingerprint).to eq(stripe_charge.card_fingerprint)
      expect(purchase.stripe_card_id).to eq(stripe_charge.card_instance_id)
      expect(purchase.card_expiry_month).to eq(stripe_charge.card_expiry_month)
      expect(purchase.card_expiry_year).to eq(stripe_charge.card_expiry_year)
      expect(purchase.was_zipcode_check_performed).to eq(!stripe_charge.zip_check_result.nil?)
      expect(purchase.flow_of_funds).to be_present
      expect(purchase.flow_of_funds).to eq stripe_charge.flow_of_funds
    end

    it "calls update_charge_details_from_processor! on the assoiated charge" do
      stripe_charge = ChargeProcessor.get_charge(StripeChargeProcessor.charge_processor_id, "ch_2OTlIf9e1RjUNIyY1adIdtGp")

      charge = create(:charge)
      purchase = create(:purchase)
      charge.purchases << purchase

      expect_any_instance_of(Charge).to receive(:update_charge_details_from_processor!).and_call_original
      purchase.save_charge_data(stripe_charge)

      expect(charge.reload.processor).to eq(StripeChargeProcessor.charge_processor_id)
      expect(charge.processor_transaction_id).to eq(stripe_charge.id)
      expect(charge.processor_fee_cents).to eq(stripe_charge.fee)
      expect(charge.processor_fee_currency).to eq(stripe_charge.fee_currency)
      expect(charge.payment_method_fingerprint).to eq(stripe_charge.card_fingerprint)
    end
  end

  describe "#refunded?" do
    it "returns false when stripe_refunded is nil or false" do
      purchase = create(:purchase, stripe_refunded: nil)
      expect(purchase.refunded?).to eq(false)
      purchase.update!(stripe_refunded: false)
      expect(purchase.refunded?).to eq(false)
    end

    it "returns true when stripe_refunded is true" do
      purchase = create(:purchase, stripe_refunded: true)
      expect(purchase.refunded?).to eq(true)
    end
  end

  describe "#chargedback?" do
    it "returns false when chargeback_date is nil" do
      purchase = create(:purchase, chargeback_date: nil)
      expect(purchase.chargedback?).to eq(false)
    end

    it "returns true when chargeback_date is not nil" do
      purchase = create(:purchase, chargeback_date: Time.current)
      expect(purchase.chargedback?).to eq(true)
    end
  end

  describe "#chargedback_not_reversed?" do
    it "returns true when chargedback" do
      purchase = create(:disputed_purchase)
      expect(purchase.chargedback_not_reversed?).to eq(true)
    end

    it "returns false when not chargedback" do
      purchase = create(:purchase)
      expect(purchase.chargedback_not_reversed?).to eq(false)
    end

    it "returns false when chargedback and reversed" do
      purchase = create(:disputed_purchase, chargeback_reversed: true)
      expect(purchase.chargedback_not_reversed?).to eq(false)
    end
  end

  describe "#chargedback_not_reversed_or_refunded?" do
    it "returns true when chargedback" do
      purchase = create(:disputed_purchase)
      expect(purchase.chargedback_not_reversed_or_refunded?).to eq(true)
    end

    it "returns false when not chargedback" do
      purchase = create(:purchase)
      expect(purchase.chargedback_not_reversed_or_refunded?).to eq(false)
    end

    it "returns false when chargedback and reversed" do
      purchase = create(:disputed_purchase, chargeback_reversed: true)
      expect(purchase.chargedback_not_reversed_or_refunded?).to eq(false)
    end

    it "returns false when refunded" do
      purchase = create(:refunded_purchase)
      expect(purchase.chargedback_not_reversed_or_refunded?).to eq(true)
    end
  end

  describe "#amount_refundable_cents" do
    let(:purchase) { create(:purchase, link: create(:product, price_currency_type: Currency::EUR), price_cents: 200) }

    it "returns the refundable amount" do
      expect(purchase.amount_refundable_cents).to eq(200)
    end

    context "for a purchase with a removed charge processor" do
      let(:purchase) { create(:purchase, price_cents: 100) }
      before { purchase.update!(charge_processor_id: "app_store") }

      it "returns zero" do
        expect(purchase.amount_refundable_cents).to eq(0)
      end
    end
  end

  describe "#amount_refundable_cents_in_currency" do
    let(:purchase) { create(:purchase, link: create(:product, price_currency_type: Currency::EUR), price_cents: 200) }

    before { allow_any_instance_of(Purchase).to receive(:get_rate).with(Currency::EUR).and_return(0.8) }

    it "returns the refundable amount in the purchase's currency" do
      expect(purchase.amount_refundable_cents_in_currency).to eq(160)
    end
  end

  describe "#shipping_information" do
    let(:purchase) { create(:purchase, link: create(:product, require_shipping: true), full_name: "Full Name", street_address: "123 Gum Rd", country: "United States", state: "NY", city: "New York", zip_code: "10025") }

    it "returns the shipping information" do
      expect(purchase.shipping_information).to eq(
        {
          full_name: "Full Name",
          street_address: "123 Gum Rd",
          city: "New York",
          state: "NY",
          zip_code: "10025",
          country: "United States",
        }
      )
    end

    context "require_shipping is false for the product" do
      before do
        purchase.link.update!(require_shipping: false)
      end

      it "returns an empty object" do
        expect(purchase.shipping_information).to eq({})
      end
    end

    context "when a value is nil" do
      before do
        purchase.update!(full_name: nil)
      end

      it "defaults to an empty string" do
        expect(purchase.shipping_information[:full_name]).to eq("")
      end
    end
  end

  describe "#name_or_email" do
    let(:purchase) { create(:purchase) }

    context "full name is nil" do
      it "returns the email" do
        expect(purchase.name_or_email).to eq(purchase.email)
      end
    end

    context "full name is empty" do
      before { purchase.update!(full_name: "") }

      it "returns the email" do
        expect(purchase.name_or_email).to eq(purchase.email)
      end
    end

    context "full name is present" do
      before { purchase.update!(full_name: "Crabcake Sam") }

      it "returns the full name" do
        expect(purchase.name_or_email).to eq("Crabcake Sam")
      end
    end
  end

  describe "#prepare_for_charge!" do
    context "in a country with taxes" do
      let(:purchase) { build(:purchase, chargeable: create(:chargeable), country: "France", ip_country: "France") }

      before do
        create(:zip_tax_rate, zip_code: nil, state: nil, country: Compliance::Countries::FRA.alpha2, combined_rate: 0.2, is_seller_responsible: false)
      end

      it "calculates taxes" do
        purchase.prepare_for_charge!
        expect(purchase.gumroad_tax_cents).to eq 20
      end

      it "does not apply taxes if merchant account is a Brazilian Stripe Connect account" do
        purchase.seller.check_merchant_account_is_linked = true
        purchase.merchant_account = create(:merchant_account_stripe_connect, user: purchase.seller, country: "BR")

        purchase.prepare_for_charge!

        expect(purchase.gumroad_tax_cents).to eq 0
        expect(purchase.tax_cents).to eq 0
      end
    end
  end

  describe "#commission" do
    let!(:commission) { create(:commission) }

    before do
      commission.update!(completion_purchase: create(:purchase, link: commission.deposit_purchase.link, is_commission_completion_purchase: true))
    end

    it "returns the commission for the deposit and completion purchases" do
      expect(commission.completion_purchase.commission).to eq(commission)
      expect(commission.deposit_purchase.commission).to eq(commission)
    end

    context "when the purchase has no associated commission" do
      let(:purchase) { create(:purchase) }

      it "returns nil" do
        expect(purchase.commission).to be_nil
      end
    end
  end

  describe "#eligible_for_review_reminder?" do
    let(:purchaser) { create(:user) }
    let(:product) { create(:product, price_cents: 10_00) }
    let(:purchase) { create(:purchase, purchaser:, link: product) }

    it "returns true when all conditions are met" do
      expect(purchase.eligible_for_review_reminder?).to be true
    end

    context "when purchaser has opted out of review reminders" do
      before { allow(purchaser).to receive(:opted_out_of_review_reminders?).and_return(true) }

      it "returns false" do
        expect(purchase.eligible_for_review_reminder?).to be false
      end
    end

    context "when purchase is subscription" do
      let(:purchase) { create(:membership_purchase) }

      context "original subscription purchase" do
        it "returns true" do
          expect(purchase.eligible_for_review_reminder?).to be true
        end
      end

      context "recurring subscription purchase" do
        let(:purchase) { create(:recurring_membership_purchase) }

        it "returns false" do
          expect(purchase.eligible_for_review_reminder?).to be false
        end
      end
    end

    context "when purchase is a bundle purchase" do
      before { purchase.update!(is_bundle_purchase: true) }

      it "returns false" do
        expect(purchase.eligible_for_review_reminder?).to be false
      end
    end

    context "when product review exists" do
      before { purchase.create_product_review }

      it "returns false" do
        expect(purchase.eligible_for_review_reminder?).to be false
      end
    end

    context "when purchase is not successful" do
      before { purchase.update!(purchase_state: "in_progress") }

      it "returns false" do
        expect(purchase.eligible_for_review_reminder?).to be false
      end
    end


    context "when purchase is refunded" do
      before { purchase.update!(stripe_refunded: true) }

      it "returns false" do
        expect(purchase.eligible_for_review_reminder?).to be false
      end
    end

    context "when purchaser is nil" do
      before { purchase.update!(purchaser: nil) }

      it "returns true" do
        expect(purchase.eligible_for_review_reminder?).to be true
      end
    end
  end

  describe "#license" do
    let(:product) { create(:membership_product) }
    let(:subscription) { create(:subscription, link: product) }
    let!(:original_purchase) { create(:purchase, link: product, subscription:, is_original_subscription_purchase: true) }

    context "when the purchase is a gifted subscription" do
      let(:gifted_purchase) { create(:purchase, subscription:, is_gift_receiver_purchase: true) }
      let!(:another_license) { create(:license, purchase: original_purchase) }

      it "returns the license of the gifted purchase" do
        gifted_license = create(:license, purchase: gifted_purchase)
        expect(gifted_purchase.license).to eq(gifted_license)
      end
    end

    context "when the purchase is not a gifted subscription" do
      let(:purchase) { create(:purchase, subscription:) }

      it "returns the license of the original purchase" do
        license = create(:license, purchase: original_purchase)
        expect(purchase.license).to eq(license)
      end
    end
  end

  describe "#formatted_total_display_price_per_unit" do
    context "normal purchase" do
      let(:purchase) { create(:purchase) }

      it "returns the formatted total display price per unit" do
        expect(purchase.formatted_total_display_price_per_unit).to eq("$1")
      end
    end

    context "commission deposit purchase", :vcr do
      let(:purchase) { create(:commission_deposit_purchase) }

      before { purchase.create_artifacts_and_send_receipt! }

      it "returns the formatted total display price" do
        expect(purchase.reload.formatted_total_display_price_per_unit).to eq("$2")
      end
    end

    context "with a tip" do
      let(:purchase) { create(:purchase, price_cents: 1000) }

      before { purchase.create_tip!(value_cents: 500) }

      it "returns the formatted total display price less the tip" do
        expect(purchase.formatted_total_display_price_per_unit).to eq("$5")
      end
    end
  end

  describe "#call" do
    context "when purchasing a call" do
      let(:subject) { build(:call_purchase) }

      it { is_expected.to validate_presence_of(:call) }

      it "marks the purchase as invalid if the call is not valid" do
        purchase = build(:call_purchase, call: build(:call, start_time: 1.day.ago))

        expect(purchase).not_to be_valid
        expect(purchase.errors.full_messages).to include("Call Selected time is no longer available")
      end
    end

    context "when not purchasing a call" do
      let(:subject) { build(:physical_purchase) }

      it { is_expected.not_to validate_presence_of(:call) }
    end
  end

  describe "#determine_affiliate_fee_cents" do
    let(:product) { create(:product, price_cents: 10_00) }
    let(:affiliate) { create(:direct_affiliate, affiliate_basis_points: 7500, products: [product]) }
    let(:affiliate_purchase) { create(:purchase, link: product, seller: product.user, affiliate:, save_card: false, ip_address:, chargeable:) }

    it "returns affiliate's share of the fee" do
      expect(affiliate_purchase.send(:determine_affiliate_fee_cents)).to eq 156.75
      expect(affiliate_purchase.send(:determine_affiliate_fee_cents)).to eq affiliate_purchase.fee_cents * 0.75
    end

    it "returns 0 if seller bears affiliate fees" do
      product.user.update!(bears_affiliate_fee: true)
      expect(affiliate_purchase.send(:determine_affiliate_fee_cents)).to eq 0
      expect(affiliate_purchase.fee_cents).to eq 209
    end
  end

  describe "#gift_purchases_cannot_be_on_installment_plans" do
    it "does not allow gift purchases to be on installment plans" do
      purchase = create(:purchase, is_installment_payment: true, installment_plan: create(:product_installment_plan))

      purchase.is_gift_receiver_purchase = true
      purchase.is_gift_sender_purchase = false
      expect(purchase).not_to be_valid
      expect(purchase.errors.full_messages).to include("Gift purchases cannot be on installment plans.")

      purchase.is_gift_receiver_purchase = true
      purchase.is_gift_sender_purchase = false
      expect(purchase).not_to be_valid
      expect(purchase.errors.full_messages).to include("Gift purchases cannot be on installment plans.")

      purchase.is_gift_receiver_purchase = false
      purchase.is_gift_sender_purchase = false
      purchase.validate
      expect(purchase.errors.full_messages).not_to include("Gift purchases cannot be on installment plans.")
    end
  end

  describe "within_refund_policy_timeframe?" do
    let(:purchase) { create(:purchase) }
    let(:refund_policy) { purchase.create_purchase_refund_policy!(title: "Refund policy", fine_print: "This is the fine print.", max_refund_period_in_days: 30) }

    before do
      allow(purchase).to receive(:purchase_refund_policy).and_return(refund_policy)
    end

    context "when purchase is not successful or gift receiver purchase was not successful or not in not_charged state" do
      it "returns false" do
        allow(purchase).to receive(:successful?).and_return(false)
        allow(purchase).to receive(:gift_receiver_purchase_successful?).and_return(false)
        allow(purchase).to receive(:not_charged?).and_return(false)

        expect(purchase.within_refund_policy_timeframe?).to be false
      end
    end

    context "when purchase is refunded or chargedback" do
      it "returns false" do
        allow(purchase).to receive(:successful?).and_return(true)
        allow(purchase).to receive(:refunded?).and_return(true)

        expect(purchase.within_refund_policy_timeframe?).to be false

        allow(purchase).to receive(:refunded?).and_return(false)
        allow(purchase).to receive(:chargedback?).and_return(true)

        expect(purchase.within_refund_policy_timeframe?).to be false
      end
    end

    context "when there is no refund policy" do
      it "returns false" do
        allow(purchase).to receive(:successful?).and_return(true)
        allow(purchase).to receive(:refunded?).and_return(false)
        allow(purchase).to receive(:chargedback?).and_return(false)
        allow(purchase).to receive(:purchase_refund_policy).and_return(nil)

        expect(purchase.within_refund_policy_timeframe?).to be false
      end
    end

    context "when refund policy max_refund_period_in_days is nil or <= 0" do
      it "returns false" do
        allow(purchase).to receive(:successful?).and_return(true)
        allow(purchase).to receive(:refunded?).and_return(false)
        allow(purchase).to receive(:chargedback?).and_return(false)

        refund_policy.max_refund_period_in_days = nil
        expect(purchase.within_refund_policy_timeframe?).to be false

        refund_policy.max_refund_period_in_days = 0
        expect(purchase.within_refund_policy_timeframe?).to be false

        refund_policy.max_refund_period_in_days = -1
        expect(purchase.within_refund_policy_timeframe?).to be false
      end
    end

    context "when the purchase is within the refund policy timeframe" do
      it "returns true" do
        allow(purchase).to receive(:successful?).and_return(true)
        allow(purchase).to receive(:refunded?).and_return(false)
        allow(purchase).to receive(:chargedback?).and_return(false)
        refund_policy.max_refund_period_in_days = 30
        purchase.created_at = 15.days.ago

        expect(purchase.within_refund_policy_timeframe?).to be true
      end
    end

    context "when the purchase is outside the refund policy timeframe" do
      it "returns false" do
        allow(purchase).to receive(:successful?).and_return(true)
        allow(purchase).to receive(:refunded?).and_return(false)
        allow(purchase).to receive(:chargedback?).and_return(false)
        refund_policy.max_refund_period_in_days = 30
        purchase.created_at = 31.days.ago

        expect(purchase.within_refund_policy_timeframe?).to be false
      end
    end
  end

  describe "#calculate_custom_fee_per_thousand" do
    it "does nothing and returns if custom fee is already set" do
      purchase = create(:purchase, custom_fee_per_thousand: 50)
      expect(purchase.custom_fee_per_thousand).to eq(50)

      expect(purchase).not_to receive(:is_recurring_subscription_charge)
      expect(purchase.seller).not_to receive(:custom_fee_per_thousand)

      purchase.send(:calculate_custom_fee_per_thousand)
      expect(purchase.custom_fee_per_thousand).to eq(50)
    end

    it "does nothing and returns if discover fee is being charged" do
      seller = create(:user)
      product = create(:product, user: seller)
      purchase = create(:purchase, link: product)
      seller.update!(custom_fee_per_thousand: 50)
      allow_any_instance_of(Purchase).to receive(:charge_discover_fee?).and_return(true)

      expect(purchase).not_to receive(:is_recurring_subscription_charge)
      expect(purchase.seller).not_to receive(:custom_fee_per_thousand)

      purchase.send(:calculate_custom_fee_per_thousand)
      expect(purchase.custom_fee_per_thousand).to be nil
    end

    context "for a recurring charge" do
      let!(:subscription) { create(:subscription) }
      let!(:original_subscription_purchase) { create(:purchase, subscription:, is_original_subscription_purchase: true) }

      context "when original subscription purchase had a custom fee" do
        it "sets custom fee same as original subscription purchase's custom fee" do
          original_subscription_purchase.update!(custom_fee_per_thousand: 50)
          original_subscription_purchase.seller.update!(custom_fee_per_thousand: 75)

          recurring_purchase = create(:purchase, subscription:, is_original_subscription_purchase: false)
          expect(recurring_purchase.reload.custom_fee_per_thousand).to be_nil

          recurring_purchase.send(:calculate_custom_fee_per_thousand)
          expect(recurring_purchase.custom_fee_per_thousand).to eq(50)
        end
      end

      context "when original subscription purchase did not have a custom fee" do
        it "does not set a custom fee" do
          original_subscription_purchase.seller.update!(custom_fee_per_thousand: 75)
          expect(original_subscription_purchase.custom_fee_per_thousand).to be_nil

          recurring_purchase = create(:purchase, subscription:, is_original_subscription_purchase: false)
          expect(recurring_purchase.reload.custom_fee_per_thousand).to be_nil

          recurring_purchase.send(:calculate_custom_fee_per_thousand)
          expect(recurring_purchase.custom_fee_per_thousand).to be_nil
        end
      end
    end

    context "for a preorder charge" do
      let!(:seller) { create(:user) }
      let!(:product) { create(:product, user: seller, price_cents: 10_00, is_in_preorder_state: true) }
      let!(:preorder_product) { create(:preorder_link, link: product) }
      let!(:authorization_purchase) do build(:purchase, link: product, chargeable: create(:chargeable),
                                                        purchase_state: "in_progress", is_preorder_authorization: true) end
      let!(:preorder) { preorder_product.build_preorder(authorization_purchase) }

      context "when preorder authorization purchase had a custom fee" do
        it "sets custom fee same as preorder authorization purchase's custom fee" do
          authorization_purchase.update!(custom_fee_per_thousand: 50)
          authorization_purchase.seller.update!(custom_fee_per_thousand: 75)

          preorder.authorize!
          preorder.mark_authorization_successful
          product.update!(is_in_preorder_state: false)
          preorder_charge = preorder.reload.charge!

          expect(preorder_charge.custom_fee_per_thousand).to eq(50)
          expect(preorder_charge.fee_cents).to eq 1_59 # 5% gumroad flat fee + 50c + 2.9% cc fee + 30c fixed cc fee

          preorder_charge.send(:calculate_custom_fee_per_thousand)
          expect(preorder_charge.custom_fee_per_thousand).to eq(50)
        end
      end

      context "when preorder authorization purchase did not have a custom fee" do
        it "does not set a custom fee" do
          preorder.authorize!
          preorder.mark_authorization_successful
          product.update!(is_in_preorder_state: false)

          authorization_purchase.seller.update!(custom_fee_per_thousand: 75)
          preorder_charge = preorder.reload.charge!

          expect(preorder_charge.custom_fee_per_thousand).to be_nil
          expect(preorder_charge.fee_cents).to eq 2_09 # 10% gumroad flat fee + 50c + 2.9% cc fee + 30c fixed cc fee

          preorder_charge.send(:calculate_custom_fee_per_thousand)
          expect(preorder_charge.custom_fee_per_thousand).to be_nil
        end
      end
    end

    context "for a regular purchase" do
      let!(:seller) { create(:user) }
      let!(:product) { create(:product, user: seller) }

      context "when seller has a custom fee set" do
        it "sets custom fee same as seller's custom fee" do
          seller.update!(custom_fee_per_thousand: 50)
          purchase = create(:purchase, link: product)
          expect(purchase.custom_fee_per_thousand).to eq(50)

          purchase.send(:calculate_custom_fee_per_thousand)
          expect(purchase.custom_fee_per_thousand).to eq(50)
        end
      end

      context "when seller does not have a custom fee set" do
        it "does not set a custom fee" do
          purchase = create(:purchase, link: product)
          expect(purchase.custom_fee_per_thousand).to be_nil

          purchase.send(:calculate_custom_fee_per_thousand)
          expect(purchase.custom_fee_per_thousand).to be_nil
        end
      end
    end

    context "for a new subscription purchase" do
      let!(:seller) { create(:user) }
      let!(:membership_product) { create(:membership_product, user: seller) }
      let!(:subscription) { create(:subscription, link: membership_product) }
      let!(:subscription_purchase) { create(:purchase, subscription:, link: membership_product, is_original_subscription_purchase: true) }

      context "when seller has a custom fee set" do
        it "sets custom fee same as seller's custom fee" do
          expect(subscription_purchase.custom_fee_per_thousand).to be_nil

          seller.update!(custom_fee_per_thousand: 25)
          subscription_purchase.send(:calculate_custom_fee_per_thousand)
          expect(subscription_purchase.custom_fee_per_thousand).to eq(25)
        end
      end

      context "when seller does not have a custom fee set" do
        it "does not set a custom fee" do
          expect(subscription_purchase.custom_fee_per_thousand).to be_nil

          subscription_purchase.send(:calculate_custom_fee_per_thousand)
          expect(subscription_purchase.custom_fee_per_thousand).to be_nil
        end
      end
    end
  end
end
