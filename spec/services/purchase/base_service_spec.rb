# frozen_string_literal: true

require "spec_helper"

describe Purchase::BaseService do
  describe "auto-restart existing subscription on checkout" do
    let(:seller) { create(:user) }
    let(:buyer) { create(:user) }
    let(:product) { create(:membership_product, user: seller) }

    let(:service_class) do
      Class.new(Purchase::BaseService) do
        attr_accessor :purchase

        def initialize(purchase)
          @purchase = purchase
        end

        def perform
          create_subscription(nil)
        end
      end
    end

    describe "when buyer has a deactivated subscription" do
      let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
      let(:existing_subscription) { existing_purchase.subscription }

      before do
        existing_subscription.update!(user: buyer, deactivated_at: 1.day.ago, failed_at: 1.day.ago)
      end

      let(:new_purchase) do
        purchase = build(:purchase, link: product, purchaser: buyer, email: buyer.email)
        purchase.is_original_subscription_purchase = true
        purchase.price = product.prices.first
        purchase.save!
        purchase
      end

      it "restarts the existing subscription instead of creating a new one" do
        initial_count = product.subscriptions.count

        service_class.new(new_purchase).perform

        expect(product.subscriptions.count).to eq(initial_count)
        expect(new_purchase.reload.subscription).to eq(existing_subscription)
        expect(existing_subscription.reload.deactivated_at).to be_nil
      end

      it "associates the new purchase with the restarted subscription" do
        service_class.new(new_purchase).perform

        expect(existing_subscription.reload.purchases).to include(new_purchase)
      end

      it "sends restart notifications" do
        expect_any_instance_of(Subscription).to receive(:send_restart_notifications!)

        service_class.new(new_purchase).perform
      end
    end

    describe "when subscription was cancelled by seller" do
      let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
      let(:existing_subscription) { existing_purchase.subscription }

      before do
        existing_subscription.update!(
          user: buyer,
          deactivated_at: 1.day.ago,
          failed_at: 1.day.ago,
          cancelled_at: 2.days.ago,
          cancelled_by_buyer: false
        )
      end

      let(:new_purchase) do
        purchase = build(:purchase, link: product, purchaser: buyer, email: buyer.email)
        purchase.is_original_subscription_purchase = true
        purchase.price = product.prices.first
        purchase.save!
        purchase
      end

      it "creates a new subscription instead of restarting" do
        initial_count = product.subscriptions.count

        service_class.new(new_purchase).perform

        expect(product.subscriptions.count).to eq(initial_count + 1)
        expect(new_purchase.reload.subscription).not_to eq(existing_subscription)
      end
    end

    describe "when subscription was cancelled by buyer" do
      let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
      let(:existing_subscription) { existing_purchase.subscription }

      before do
        existing_subscription.update!(
          user: buyer,
          deactivated_at: 1.day.ago,
          failed_at: 1.day.ago,
          cancelled_at: 2.days.ago,
          cancelled_by_buyer: true
        )
      end

      let(:new_purchase) do
        purchase = build(:purchase, link: product, purchaser: buyer, email: buyer.email)
        purchase.is_original_subscription_purchase = true
        purchase.price = product.prices.first
        purchase.save!
        purchase
      end

      it "restarts the existing subscription" do
        initial_count = product.subscriptions.count

        service_class.new(new_purchase).perform

        expect(product.subscriptions.count).to eq(initial_count)
        expect(new_purchase.reload.subscription).to eq(existing_subscription)
        expect(existing_subscription.reload.deactivated_at).to be_nil
      end
    end

    describe "when subscription has ended" do
      let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
      let(:existing_subscription) { existing_purchase.subscription }

      before do
        existing_subscription.update!(user: buyer, deactivated_at: 1.day.ago, failed_at: 1.day.ago, ended_at: Time.current)
      end

      let(:new_purchase) do
        purchase = build(:purchase, link: product, purchaser: buyer, email: buyer.email)
        purchase.is_original_subscription_purchase = true
        purchase.price = product.prices.first
        purchase.save!
        purchase
      end

      it "creates a new subscription instead of restarting" do
        initial_count = product.subscriptions.count

        service_class.new(new_purchase).perform

        expect(product.subscriptions.count).to eq(initial_count + 1)
        expect(new_purchase.reload.subscription).not_to eq(existing_subscription)
      end
    end

    describe "when matching by email without user association" do
      let(:guest_email) { "guest@example.com" }
      let!(:existing_purchase) { create(:membership_purchase, link: product, email: guest_email) }
      let(:existing_subscription) { existing_purchase.subscription }

      before do
        existing_subscription.update!(user: nil, deactivated_at: 1.day.ago, failed_at: 1.day.ago)
      end

      let(:new_purchase) do
        purchase = build(:purchase, link: product, purchaser: nil, email: guest_email)
        purchase.is_original_subscription_purchase = true
        purchase.price = product.prices.first
        purchase.save!
        purchase
      end

      it "restarts the subscription when email matches" do
        initial_count = product.subscriptions.count

        service_class.new(new_purchase).perform

        expect(product.subscriptions.count).to eq(initial_count)
        expect(new_purchase.reload.subscription).to eq(existing_subscription)
        expect(existing_subscription.reload.deactivated_at).to be_nil
      end
    end

    describe "when no matching subscription exists" do
      let(:different_buyer) { create(:user) }

      let(:new_purchase) do
        purchase = build(:purchase, link: product, purchaser: different_buyer, email: different_buyer.email)
        purchase.is_original_subscription_purchase = true
        purchase.price = product.prices.first
        purchase.save!
        purchase
      end

      it "creates a new subscription" do
        expect(product.subscriptions.count).to eq(0)

        service_class.new(new_purchase).perform

        expect(product.subscriptions.count).to eq(1)
        expect(new_purchase.reload.subscription).to be_present
      end
    end

    describe "when multiple deactivated subscriptions exist" do
      let!(:older_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
      let(:older_subscription) { older_purchase.subscription }
      let!(:newer_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
      let(:newer_subscription) { newer_purchase.subscription }

      before do
        older_subscription.update!(user: buyer, deactivated_at: 5.days.ago, failed_at: 5.days.ago)
        newer_subscription.update!(user: buyer, deactivated_at: 1.day.ago, failed_at: 1.day.ago)
      end

      let(:new_purchase) do
        purchase = build(:purchase, link: product, purchaser: buyer, email: buyer.email)
        purchase.is_original_subscription_purchase = true
        purchase.price = product.prices.first
        purchase.save!
        purchase
      end

      it "restarts the most recently deactivated subscription" do
        initial_count = product.subscriptions.count

        service_class.new(new_purchase).perform

        expect(product.subscriptions.count).to eq(initial_count)
        expect(new_purchase.reload.subscription).to eq(newer_subscription)
        expect(newer_subscription.reload.deactivated_at).to be_nil
        expect(older_subscription.reload.deactivated_at).to be_present
      end
    end

    describe "when subscription is a test subscription" do
      let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
      let(:existing_subscription) { existing_purchase.subscription }

      before do
        existing_subscription.update!(user: buyer, deactivated_at: 1.day.ago, failed_at: 1.day.ago, is_test_subscription: true)
      end

      let(:new_purchase) do
        purchase = build(:purchase, link: product, purchaser: buyer, email: buyer.email)
        purchase.is_original_subscription_purchase = true
        purchase.price = product.prices.first
        purchase.save!
        purchase
      end

      it "creates a new subscription instead of restarting the test subscription" do
        initial_count = product.subscriptions.count

        service_class.new(new_purchase).perform

        expect(product.subscriptions.count).to eq(initial_count + 1)
        expect(new_purchase.reload.subscription).not_to eq(existing_subscription)
      end
    end

    describe "when purchase is a test purchase" do
      let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: seller) }
      let(:existing_subscription) { existing_purchase.subscription }

      before do
        existing_subscription.update!(user: seller, deactivated_at: 1.day.ago, failed_at: 1.day.ago)
      end

      let(:new_purchase) do
        purchase = build(:purchase, link: product, purchaser: seller, email: seller.email)
        purchase.is_original_subscription_purchase = true
        purchase.price = product.prices.first
        purchase.save!
        purchase
      end

      it "creates a new subscription instead of restarting with test purchase" do
        initial_count = product.subscriptions.count

        service_class.new(new_purchase).perform

        expect(product.subscriptions.count).to eq(initial_count + 1)
        expect(new_purchase.reload.subscription).not_to eq(existing_subscription)
      end
    end

    describe "when product is deleted" do
      let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
      let(:existing_subscription) { existing_purchase.subscription }

      before do
        existing_subscription.update!(user: buyer, deactivated_at: 1.day.ago, failed_at: 1.day.ago)
        product.update!(deleted_at: Time.current)
      end

      let(:new_purchase) do
        purchase = build(:purchase, link: product, purchaser: buyer, email: buyer.email)
        purchase.is_original_subscription_purchase = true
        purchase.price = product.prices.first
        purchase.save!
        purchase
      end

      it "creates a new subscription instead of restarting" do
        initial_count = product.subscriptions.count

        service_class.new(new_purchase).perform

        expect(product.subscriptions.count).to eq(initial_count + 1)
        expect(new_purchase.reload.subscription).not_to eq(existing_subscription)
      end
    end
  end
end
