# frozen_string_literal: true

require "spec_helper"

describe PaymentOption do
  describe "validation" do
    it "considers a PaymentOption to be invalid unless all required information is provided" do
      payment_option = PaymentOption.new
      expect(payment_option.valid?).to eq false

      product = create(:subscription_product)
      subscription = create(:subscription, link: product)

      payment_option.subscription = subscription
      expect(payment_option.valid?).to eq false

      payment_option.price = product.prices.last
      expect(payment_option.valid?).to eq true
    end

    it "requires installment_plan when subscription is an installment plan" do
      subscription = create(:subscription, is_installment_plan: false)

      payment_option = build(:payment_option, subscription:, installment_plan: nil)
      expect(payment_option.valid?).to eq true

      subscription.update!(is_installment_plan: true)
      expect(payment_option.valid?).to eq false

      installment_plan = build(:product_installment_plan)
      payment_option.installment_plan = installment_plan
      expect(payment_option.valid?).to eq true
    end
  end

  describe "#update_subscription_last_payment_option" do
    it "sets correct payment_option on creation and destruction" do
      subscription = create(:subscription)
      payment_option_1 = create(:payment_option, subscription:)
      expect(subscription.reload.last_payment_option).to eq(payment_option_1)

      payment_option_2 = create(:payment_option, subscription:)
      payment_option_3 = create(:payment_option, subscription:)
      expect(subscription.reload.last_payment_option).to eq(payment_option_3)

      payment_option_3.destroy
      expect(subscription.reload.last_payment_option).to eq(payment_option_2)

      payment_option_2.mark_deleted!
      expect(subscription.reload.last_payment_option).to eq(payment_option_1)

      payment_option_2.mark_undeleted!
      expect(subscription.reload.last_payment_option).to eq(payment_option_2)
    end
  end
end
