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

  describe "installment plan snapshot" do
    let(:product) { create(:product, price_cents: 1000) }
    let!(:installment_plan) do
      create(:product_installment_plan,
             link: product,
             number_of_installments: 3,
             recurrence: "monthly")
    end
    let(:subscription) { create(:subscription, link: product, is_installment_plan: true) }

    describe "#snapshot_installment_config" do
      it "snapshots installment config on creation" do
        payment_option = subscription.payment_options.create!(
          price: product.default_price,
          installment_plan:
        )

        expect(payment_option.number_of_installments).to eq(3)
        expect(payment_option.recurrence).to eq("monthly")
      end

      it "preserves snapshot when product installment plan changes" do
        payment_option = subscription.payment_options.create!(
          price: product.default_price,
          installment_plan:
        )

        original_installments = payment_option.number_of_installments
        original_recurrence = payment_option.recurrence

        # Seller changes product config (from 3 installments to 2)
        installment_plan.update!(number_of_installments: 2)

        # Payment option should still have original snapshot values
        payment_option.reload
        expect(payment_option.number_of_installments).to eq(original_installments)
        expect(payment_option.recurrence).to eq(original_recurrence)
        expect(payment_option.number_of_installments).to eq(3) # Still 3, NOT 2
      end

      it "does not snapshot for non-installment subscriptions" do
        regular_subscription = create(:subscription, link: product, is_installment_plan: false)

        payment_option = regular_subscription.payment_options.create!(
          price: product.default_price,
          installment_plan: nil
        )

        expect(payment_option.number_of_installments).to be_nil
        expect(payment_option.recurrence).to be_nil
      end
    end

    describe "validations for installment plans" do
      it "requires number_of_installments for installment plan subscriptions" do
        # Build without installment_plan first, then set snapshot fields manually
        payment_option = subscription.payment_options.build(
          price: product.default_price
        )
        # Manually set only recurrence to test number_of_installments validation
        payment_option.recurrence = "monthly"
        payment_option.number_of_installments = nil

        expect(payment_option.valid?).to eq(false)
        expect(payment_option.errors[:number_of_installments]).to be_present
      end

      it "requires recurrence for installment plan subscriptions" do
        # Build without installment_plan first, then set snapshot fields manually
        payment_option = subscription.payment_options.build(
          price: product.default_price
        )
        # Manually set only number_of_installments to test recurrence validation
        payment_option.number_of_installments = 3
        payment_option.recurrence = nil

        expect(payment_option.valid?).to eq(false)
        expect(payment_option.errors[:recurrence]).to be_present
      end

      it "allows nil snapshot fields for non-installment subscriptions" do
        regular_subscription = create(:subscription, link: product, is_installment_plan: false)

        payment_option = regular_subscription.payment_options.build(
          price: product.default_price,
          installment_plan: nil,
          number_of_installments: nil,
          recurrence: nil
        )

        expect(payment_option.valid?).to eq(true)
      end
    end
  end
end
