# frozen_string_literal: true

require "test_helper"

class SubscriptionRestartableTest < ActiveSupport::TestCase
  self.described_class = Subscription::Restartable



  context_ Subscription::Restartable, :sidekiq_inline do
    let(:seller) { create(:user) }
    let(:product) { create(:membership_product, user: seller) }
    let(:buyer) { create(:user) }

    # Helper to create a subscription with a proper original purchase
    def create_subscription_with_purchase(product:, purchaser:, **subscription_attrs)
      subscription = create(:subscription, link: product, user: purchaser)
      # Create purchase directly to avoid card charging issues
      create(:purchase,
             link: product,
             purchaser: purchaser,
             email: purchaser.email,
             subscription: subscription,
             is_original_subscription_purchase: true,
             price_cents: product.price_cents,
             variant_attributes: product.tiers.to_a
      )
      subscription.update!(subscription_attrs) if subscription_attrs.present?
      subscription
    end

  context_ ".restartable_for_product_and_buyer" do
  context_ "when product is not a membership" do
        let(:regular_product) { create(:product, user: seller) }

  test "returns nil" do
          expect(Subscription.restartable_for_product_and_buyer(product: regular_product, buyer: buyer)).to be_nil
        end
      end

  context_ "when user has a cancelled subscription" do
        let!(:subscription) do
          create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            cancelled_at: 1.day.ago,
            cancelled_by_buyer: true,
            deactivated_at: 1.day.ago
          )
        end

  test "returns the subscription" do
          result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to eq(subscription)
        end
      end

  context_ "when user has a failed subscription" do
        let!(:subscription) do
          create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            failed_at: 1.day.ago,
            deactivated_at: 1.day.ago
          )
        end

  test "returns the subscription" do
          result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to eq(subscription)
        end
      end

  context_ "when subscription is cancelled by seller" do
        let!(:subscription) do
          create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            cancelled_at: 1.day.ago,
            cancelled_by_buyer: false,
            cancelled_by_admin: true,
            deactivated_at: 1.day.ago
          )
        end

  test "returns nil (not restartable)" do
          result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to be_nil
        end
      end

  context_ "when subscription has ended" do
        let!(:subscription) do
          create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            ended_at: 1.day.ago,
            deactivated_at: 1.day.ago
          )
        end

  test "returns nil (not restartable)" do
          result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to be_nil
        end
      end

  context_ "when subscription is active" do
        let!(:subscription) do
          create_subscription_with_purchase(product: product, purchaser: buyer)
        end

  test "returns nil (already active, not restartable)" do
          result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to be_nil
        end
      end

  context_ "when user has a deactivated test subscription" do
        let!(:subscription) do
          create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            is_test_subscription: true,
            cancelled_at: 1.day.ago,
            cancelled_by_buyer: true,
            deactivated_at: 1.day.ago
          )
        end

  test "returns nil (test subscriptions are excluded)" do
          result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to be_nil
        end
      end

  context_ "when user has no subscription" do
  test "returns nil" do
          result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to be_nil
        end
      end

  context_ "with multiple subscriptions" do
        let!(:older_subscription) do
          sub = create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            cancelled_at: 2.months.ago,
            cancelled_by_buyer: true,
            deactivated_at: 2.months.ago
          )
          sub.update_column(:created_at, 2.months.ago)
          sub
        end

        let!(:newer_subscription) do
          sub = create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            cancelled_at: 1.day.ago,
            cancelled_by_buyer: true,
            deactivated_at: 1.day.ago
          )
          sub.update_column(:created_at, 1.month.ago)
          sub
        end

  test "returns the most recently created subscription" do
          result = Subscription.restartable_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to eq(newer_subscription)
        end
      end
    end

  context_ ".restartable_for_product_and_email" do
  context_ "when user has a cancelled subscription" do
        let!(:subscription) do
          create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            cancelled_at: 1.day.ago,
            cancelled_by_buyer: true,
            deactivated_at: 1.day.ago
          )
        end

  test "returns the subscription when matching by email" do
          result = Subscription.restartable_for_product_and_email(product: product, email: buyer.email)
          expect(result).to eq(subscription)
        end

  test "handles email case insensitivity" do
          result = Subscription.restartable_for_product_and_email(product: product, email: buyer.email.upcase)
          expect(result).to eq(subscription)
        end
      end

  context_ "when user has a deactivated test subscription" do
        let!(:subscription) do
          create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            is_test_subscription: true,
            cancelled_at: 1.day.ago,
            cancelled_by_buyer: true,
            deactivated_at: 1.day.ago
          )
        end

  test "returns nil (test subscriptions are excluded)" do
          result = Subscription.restartable_for_product_and_email(product: product, email: buyer.email)
          expect(result).to be_nil
        end
      end
    end

  context_ ".active_for_product_and_buyer" do
  context_ "when product is not a membership" do
        let(:regular_product) { create(:product, user: seller) }

  test "returns nil" do
          expect(Subscription.active_for_product_and_buyer(product: regular_product, buyer: buyer)).to be_nil
        end
      end

  context_ "when user has an active subscription" do
        let!(:subscription) do
          create_subscription_with_purchase(product: product, purchaser: buyer)
        end

  test "returns the subscription" do
          result = Subscription.active_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to eq(subscription)
        end
      end

  context_ "when user has a pending cancellation subscription" do
        let!(:subscription) do
          create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            cancelled_at: 1.month.from_now,
            cancelled_by_buyer: true
          )
        end

  test "returns the subscription (still active until cancellation date)" do
          result = Subscription.active_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to eq(subscription)
        end
      end

  context_ "when user has a cancelled subscription" do
        let!(:subscription) do
          create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            cancelled_at: 1.day.ago,
            cancelled_by_buyer: true,
            deactivated_at: 1.day.ago
          )
        end

  test "returns nil (not active)" do
          result = Subscription.active_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to be_nil
        end
      end

  context_ "when user has a failed subscription" do
        let!(:subscription) do
          create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            failed_at: 1.day.ago,
            deactivated_at: 1.day.ago
          )
        end

  test "returns nil (not active)" do
          result = Subscription.active_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to be_nil
        end
      end

  context_ "when user has no subscription" do
  test "returns nil" do
          result = Subscription.active_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to be_nil
        end
      end

  context_ "when user has a test subscription" do
        let!(:subscription) do
          create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            is_test_subscription: true
          )
        end

  test "returns nil (test subscriptions are excluded)" do
          result = Subscription.active_for_product_and_buyer(product: product, buyer: buyer)
          expect(result).to be_nil
        end
      end
    end

  context_ ".active_for_product_and_email" do
  context_ "when user has an active subscription" do
        let!(:subscription) do
          create_subscription_with_purchase(product: product, purchaser: buyer)
        end

  test "returns the subscription when matching by email" do
          result = Subscription.active_for_product_and_email(product: product, email: buyer.email)
          expect(result).to eq(subscription)
        end

  test "handles email case insensitivity" do
          result = Subscription.active_for_product_and_email(product: product, email: buyer.email.upcase)
          expect(result).to eq(subscription)
        end
      end

  context_ "when user has a test subscription" do
        let!(:subscription) do
          create_subscription_with_purchase(
            product: product,
            purchaser: buyer,
            is_test_subscription: true
          )
        end

  test "returns nil (test subscriptions are excluded)" do
          result = Subscription.active_for_product_and_email(product: product, email: buyer.email)
          expect(result).to be_nil
        end
      end
    end
  end
end
