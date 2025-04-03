# frozen_string_literal: true

describe CancelSubscriptionsForProductWorker do
  describe "#perform" do
    before do
      @product = create(:membership_product, subscription_duration: "monthly", deleted_at: 1.day.ago)
      @subscription = create(:subscription, link: @product)
      @product.subscriptions << @subscription
      create(:purchase, subscription: @subscription, link: @product, is_original_subscription_purchase: true)
    end

    it "cancels the subscriptions" do
      expect(@subscription.alive?).to eq(true)

      described_class.new.perform(@product.id)

      expect(@subscription.reload.alive?).to eq(false)
    end

    it "sends out the email" do
      expect do
        described_class.new.perform(@product.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :subscription_product_deleted).with(@product.id)
    end

    it "doesn't cancel the subscriptions for a published product" do
      @product.publish!
      expect(@subscription.alive?).to eq(true)

      described_class.new.perform(@product.id)

      expect(@subscription.reload.alive?).to eq(true)
    end
  end
end
