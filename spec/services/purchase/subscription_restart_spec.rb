# frozen_string_literal: true

require "spec_helper"

describe Purchase::BaseService, "subscription restart on checkout" do
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

  def build_new_purchase(purchaser:, email:)
    purchase = build(:purchase, link: product, purchaser: purchaser, email: email)
    purchase.is_original_subscription_purchase = true
    purchase.price = product.prices.first
    purchase.save!
    purchase
  end

  describe "auto-restart for deactivated subscription" do
    let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
    let(:existing_subscription) { existing_purchase.subscription }
    let(:new_purchase) { build_new_purchase(purchaser: buyer, email: buyer.email) }

    before do
      existing_subscription.update!(user: buyer, deactivated_at: 1.day.ago, failed_at: 1.day.ago)
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

    it "preserves the purchase's credit card on the subscription" do
      original_card = new_purchase.credit_card

      service_class.new(new_purchase).perform

      expect(existing_subscription.reload.credit_card).to eq(original_card)
    end
  end

  describe "subscription cancelled by seller" do
    let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
    let(:existing_subscription) { existing_purchase.subscription }
    let(:new_purchase) { build_new_purchase(purchaser: buyer, email: buyer.email) }

    before do
      existing_subscription.update!(
        user: buyer,
        deactivated_at: 1.day.ago,
        cancelled_at: 2.days.ago,
        cancelled_by_buyer: false
      )
    end

    it "creates a new subscription instead of restarting" do
      initial_count = product.subscriptions.count

      service_class.new(new_purchase).perform

      expect(product.subscriptions.count).to eq(initial_count + 1)
      expect(new_purchase.reload.subscription).not_to eq(existing_subscription)
    end
  end

  describe "subscription cancelled by buyer" do
    let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
    let(:existing_subscription) { existing_purchase.subscription }
    let(:new_purchase) { build_new_purchase(purchaser: buyer, email: buyer.email) }

    before do
      existing_subscription.update!(
        user: buyer,
        deactivated_at: 1.day.ago,
        cancelled_at: 2.days.ago,
        cancelled_by_buyer: true
      )
    end

    it "restarts the existing subscription" do
      initial_count = product.subscriptions.count

      service_class.new(new_purchase).perform

      expect(product.subscriptions.count).to eq(initial_count)
      expect(new_purchase.reload.subscription).to eq(existing_subscription)
      expect(existing_subscription.reload.deactivated_at).to be_nil
    end
  end

  describe "subscription has ended" do
    let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
    let(:existing_subscription) { existing_purchase.subscription }
    let(:new_purchase) { build_new_purchase(purchaser: buyer, email: buyer.email) }

    before do
      existing_subscription.update!(
        user: buyer,
        deactivated_at: 1.day.ago,
        ended_at: Time.current
      )
    end

    it "creates a new subscription instead of restarting ended subscription" do
      initial_count = product.subscriptions.count

      service_class.new(new_purchase).perform

      expect(product.subscriptions.count).to eq(initial_count + 1)
      expect(new_purchase.reload.subscription).not_to eq(existing_subscription)
    end
  end

  describe "email matching without user association" do
    let(:guest_email) { "guest@example.com" }
    let!(:existing_purchase) { create(:membership_purchase, link: product, email: guest_email) }
    let(:existing_subscription) { existing_purchase.subscription }
    let(:new_purchase) { build_new_purchase(purchaser: nil, email: guest_email) }

    before do
      existing_subscription.update!(user: nil, deactivated_at: 1.day.ago, failed_at: 1.day.ago)
    end

    it "restarts the subscription when email matches" do
      initial_count = product.subscriptions.count

      service_class.new(new_purchase).perform

      expect(product.subscriptions.count).to eq(initial_count)
      expect(new_purchase.reload.subscription).to eq(existing_subscription)
    end
  end

  describe "case-insensitive email matching" do
    let(:guest_email) { "Guest@EXAMPLE.com" }
    let!(:existing_purchase) { create(:membership_purchase, link: product, email: guest_email) }
    let(:existing_subscription) { existing_purchase.subscription }
    let(:new_purchase) { build_new_purchase(purchaser: nil, email: "guest@example.com") }

    before do
      existing_subscription.update!(user: nil, deactivated_at: 1.day.ago, failed_at: 1.day.ago)
    end

    it "matches email case-insensitively" do
      initial_count = product.subscriptions.count

      service_class.new(new_purchase).perform

      expect(product.subscriptions.count).to eq(initial_count)
      expect(new_purchase.reload.subscription).to eq(existing_subscription)
    end
  end

  describe "no matching subscription exists" do
    let(:different_buyer) { create(:user) }
    let(:new_purchase) { build_new_purchase(purchaser: different_buyer, email: different_buyer.email) }

    it "creates a new subscription" do
      expect(product.subscriptions.count).to eq(0)

      service_class.new(new_purchase).perform

      expect(product.subscriptions.count).to eq(1)
      expect(new_purchase.reload.subscription).to be_present
    end
  end

  describe "multiple deactivated subscriptions exist" do
    let!(:older_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
    let(:older_subscription) { older_purchase.subscription }
    let!(:newer_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
    let(:newer_subscription) { newer_purchase.subscription }
    let(:new_purchase) { build_new_purchase(purchaser: buyer, email: buyer.email) }

    before do
      older_subscription.update!(user: buyer, deactivated_at: 5.days.ago, failed_at: 5.days.ago)
      newer_subscription.update!(user: buyer, deactivated_at: 1.day.ago, failed_at: 1.day.ago)
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

  describe "test subscription" do
    let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
    let(:existing_subscription) { existing_purchase.subscription }
    let(:new_purchase) { build_new_purchase(purchaser: buyer, email: buyer.email) }

    before do
      existing_subscription.update!(
        user: buyer,
        deactivated_at: 1.day.ago,
        failed_at: 1.day.ago,
        is_test_subscription: true
      )
    end

    it "creates a new subscription instead of restarting test subscription" do
      initial_count = product.subscriptions.count

      service_class.new(new_purchase).perform

      expect(product.subscriptions.count).to eq(initial_count + 1)
      expect(new_purchase.reload.subscription).not_to eq(existing_subscription)
    end
  end

  describe "test purchase" do
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

    it "creates a new subscription for test purchase" do
      initial_count = product.subscriptions.count

      service_class.new(new_purchase).perform

      expect(product.subscriptions.count).to eq(initial_count + 1)
      expect(new_purchase.reload.subscription).not_to eq(existing_subscription)
    end
  end

  describe "deleted product" do
    let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
    let(:existing_subscription) { existing_purchase.subscription }
    let(:new_purchase) { build_new_purchase(purchaser: buyer, email: buyer.email) }

    before do
      existing_subscription.update!(user: buyer, deactivated_at: 1.day.ago, failed_at: 1.day.ago)
      product.update!(deleted_at: Time.current)
    end

    it "creates a new subscription instead of restarting" do
      initial_count = product.subscriptions.count

      service_class.new(new_purchase).perform

      expect(product.subscriptions.count).to eq(initial_count + 1)
      expect(new_purchase.reload.subscription).not_to eq(existing_subscription)
    end
  end

  describe "installment payment check" do
    let!(:existing_purchase) { create(:membership_purchase, link: product, purchaser: buyer) }
    let(:existing_subscription) { existing_purchase.subscription }

    before do
      existing_subscription.update!(user: buyer, deactivated_at: 1.day.ago, failed_at: 1.day.ago)
    end

    it "find_restartable_subscription returns nil for installment payments" do
      purchase = build(:purchase, link: product, purchaser: buyer, email: buyer.email)
      purchase.is_original_subscription_purchase = true
      purchase.is_installment_payment = true
      purchase.price = product.prices.first
      purchase.save!

      service = service_class.new(purchase)
      result = service.send(:find_restartable_subscription, nil)

      expect(result).to be_nil
    end
  end
end

describe Subscription, ".find_restartable_for_checkout" do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:membership_product, user: seller) }

  it "returns nil when no subscriptions exist" do
    result = Subscription.find_restartable_for_checkout(link: product, user: buyer, email: buyer.email)
    expect(result).to be_nil
  end

  it "finds restartable subscription by user" do
    purchase = create(:membership_purchase, link: product, purchaser: buyer)
    subscription = purchase.subscription
    subscription.update!(user: buyer, deactivated_at: 1.day.ago, failed_at: 1.day.ago)

    result = Subscription.find_restartable_for_checkout(link: product, user: buyer, email: buyer.email)
    expect(result).to eq(subscription)
  end

  it "finds restartable subscription by email when user is nil" do
    email = "guest@example.com"
    purchase = create(:membership_purchase, link: product, email: email)
    subscription = purchase.subscription
    subscription.update!(user: nil, deactivated_at: 1.day.ago, failed_at: 1.day.ago)

    result = Subscription.find_restartable_for_checkout(link: product, user: nil, email: email)
    expect(result).to eq(subscription)
  end

  it "prioritizes user match over email match" do
    shared_email = "shared@example.com"
    purchase1 = create(:membership_purchase, link: product, purchaser: buyer, email: shared_email)
    subscription1 = purchase1.subscription
    subscription1.update!(user: buyer, deactivated_at: 1.day.ago, failed_at: 1.day.ago)

    other_buyer = create(:user)
    purchase2 = create(:membership_purchase, link: product, purchaser: other_buyer, email: shared_email)
    subscription2 = purchase2.subscription
    subscription2.update!(user: other_buyer, deactivated_at: 2.days.ago, failed_at: 2.days.ago)

    result = Subscription.find_restartable_for_checkout(link: product, user: buyer, email: shared_email)
    expect(result).to eq(subscription1)
  end

  it "excludes test subscriptions" do
    purchase = create(:membership_purchase, link: product, purchaser: buyer)
    subscription = purchase.subscription
    subscription.update!(user: buyer, deactivated_at: 1.day.ago, is_test_subscription: true)

    result = Subscription.find_restartable_for_checkout(link: product, user: buyer, email: buyer.email)
    expect(result).to be_nil
  end

  it "excludes ended subscriptions" do
    purchase = create(:membership_purchase, link: product, purchaser: buyer)
    subscription = purchase.subscription
    subscription.update!(user: buyer, deactivated_at: 1.day.ago, ended_at: Time.current)

    result = Subscription.find_restartable_for_checkout(link: product, user: buyer, email: buyer.email)
    expect(result).to be_nil
  end

  it "excludes subscriptions cancelled by seller" do
    purchase = create(:membership_purchase, link: product, purchaser: buyer)
    subscription = purchase.subscription
    subscription.update!(
      user: buyer,
      deactivated_at: 1.day.ago,
      cancelled_at: 2.days.ago,
      cancelled_by_buyer: false
    )

    result = Subscription.find_restartable_for_checkout(link: product, user: buyer, email: buyer.email)
    expect(result).to be_nil
  end

  it "includes subscriptions cancelled by buyer" do
    purchase = create(:membership_purchase, link: product, purchaser: buyer)
    subscription = purchase.subscription
    subscription.update!(
      user: buyer,
      deactivated_at: 1.day.ago,
      cancelled_at: 2.days.ago,
      cancelled_by_buyer: true
    )

    result = Subscription.find_restartable_for_checkout(link: product, user: buyer, email: buyer.email)
    expect(result).to eq(subscription)
  end
end

describe Subscription, ".restartable scope" do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:membership_product, user: seller) }

  it "includes deactivated subscriptions not ended and not cancelled by seller" do
    purchase = create(:membership_purchase, link: product, purchaser: buyer)
    subscription = purchase.subscription
    subscription.update!(deactivated_at: 1.day.ago, failed_at: 1.day.ago)

    expect(product.subscriptions.restartable).to include(subscription)
  end

  it "excludes active subscriptions" do
    purchase = create(:membership_purchase, link: product, purchaser: buyer)
    subscription = purchase.subscription

    expect(product.subscriptions.restartable).not_to include(subscription)
  end

  it "excludes test subscriptions" do
    purchase = create(:membership_purchase, link: product, purchaser: buyer)
    subscription = purchase.subscription
    subscription.update!(deactivated_at: 1.day.ago, is_test_subscription: true)

    expect(product.subscriptions.restartable).not_to include(subscription)
  end

  it "excludes ended subscriptions" do
    purchase = create(:membership_purchase, link: product, purchaser: buyer)
    subscription = purchase.subscription
    subscription.update!(deactivated_at: 1.day.ago, ended_at: Time.current)

    expect(product.subscriptions.restartable).not_to include(subscription)
  end

  it "excludes subscriptions cancelled by seller" do
    purchase = create(:membership_purchase, link: product, purchaser: buyer)
    subscription = purchase.subscription
    subscription.update!(deactivated_at: 1.day.ago, cancelled_at: 2.days.ago, cancelled_by_buyer: false)

    expect(product.subscriptions.restartable).not_to include(subscription)
  end

  it "includes subscriptions cancelled by buyer" do
    purchase = create(:membership_purchase, link: product, purchaser: buyer)
    subscription = purchase.subscription
    subscription.update!(deactivated_at: 1.day.ago, cancelled_at: 2.days.ago, cancelled_by_buyer: true)

    expect(product.subscriptions.restartable).to include(subscription)
  end
end
