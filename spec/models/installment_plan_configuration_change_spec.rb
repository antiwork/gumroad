# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Installment Plan Configuration Changes", type: :model do
  describe Purchase, "#frozen_installment_config" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller, price_cents: 1000) }
    let!(:installment_plan) do
      create(:product_installment_plan,
             link: product,
             number_of_installments: 3,
             recurrence: "monthly")
    end
    let(:subscription) do
      create(:subscription,
             link: product,
             is_installment_plan: true,
             installment_plan:)
    end
    let(:purchase) do
      create(:purchase,
             link: product,
             subscription:,
             is_installment_payment: true,
             installment_plan:,
             price_cents: 334)
    end

    it "returns frozen config from payment option snapshot" do
      # Purchase creation should have triggered payment_option creation via subscription
      expect(subscription.payment_options.count).to eq(1)

      payment_option = subscription.payment_options.first
      expect(payment_option.number_of_installments).to eq(3)
      expect(payment_option.recurrence).to eq("monthly")

      config = purchase.frozen_installment_config

      expect(config).to be_a(FrozenInstallmentConfig)
      expect(config.number_of_installments).to eq(3)
      expect(config.recurrence).to eq("monthly")
    end

    it "returns same config even after product plan changes" do
      original_config = purchase.frozen_installment_config
      expect(original_config.number_of_installments).to eq(3)

      # Seller changes product to 2 installments
      installment_plan.update!(number_of_installments: 2)

      # Config should still reflect original agreement
      updated_config = purchase.frozen_installment_config
      expect(updated_config.number_of_installments).to eq(3) # Still 3!
      expect(updated_config.recurrence).to eq("monthly") # Still monthly!
    end

    it "returns nil for non-installment purchases" do
      regular_purchase = create(:purchase, link: product, is_installment_payment: false)

      expect(regular_purchase.frozen_installment_config).to be_nil
    end

    context "backwards compatibility" do
      it "falls back to live plan if snapshot not available" do
        # Simulate old payment option without snapshot
        payment_option = subscription.payment_options.last
        payment_option.update_columns(number_of_installments: nil, recurrence: nil)

        config = purchase.frozen_installment_config

        expect(config).to be_a(FrozenInstallmentConfig)
        expect(config.number_of_installments).to eq(3)
        expect(config.recurrence).to eq("monthly")
      end
    end
  end

  describe Purchase, "#calculate_installment_payment_price_cents" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller, price_cents: 1000) }
    let(:installment_plan) do
      create(:product_installment_plan,
             link: product,
             number_of_installments: 3,
             recurrence: "monthly")
    end

    context "when product installment config changes" do
      it "uses frozen config, not current product config" do
        # Create first purchase: $10 in 3 installments = [$3.34, $3.33, $3.33]
        purchase_1 = create(:purchase,
                            link: product,
                            is_installment_payment: true,
                            price_cents: 334)
        subscription = purchase_1.subscription

        # Setup payment option with snapshot
        subscription.payment_options.create!(
          price: product.default_price,
          installment_plan:,
          number_of_installments: 3,
          recurrence: "monthly"
        )

        # Verify first payment amount
        expect(purchase_1.calculate_installment_payment_price_cents(1000)).to eq(334)

        # Create second purchase (2nd installment)
        purchase_2 = create(:purchase,
                            link: product,
                            subscription:,
                            is_installment_payment: true)
        expect(purchase_2.calculate_installment_payment_price_cents(1000)).to eq(333)

        # Seller changes product to 2 installments
        installment_plan.update!(number_of_installments: 2)

        # Third purchase should STILL use original 3-installment config
        purchase_3 = create(:purchase,
                            link: product,
                            subscription:,
                            is_installment_payment: true)

        # Should be $3.33 (1/3 of $10), NOT $5.00 (1/2 of $10)
        expect(purchase_3.calculate_installment_payment_price_cents(1000)).to eq(333)
        expect(purchase_3.calculate_installment_payment_price_cents(1000)).not_to eq(500)
      end

      it "protects customer from paying more than agreed" do
        # Original agreement: 3 installments of $10 = $3.34 + $3.33 + $3.33
        purchase = create(:purchase,
                          link: product,
                          is_installment_payment: true,
                          price_cents: 334)
        subscription = purchase.subscription

        subscription.payment_options.create!(
          price: product.default_price,
          installment_plan:,
          number_of_installments: 3,
          recurrence: "monthly"
        )

        # Calculate all installment amounts
        installment_1 = purchase.calculate_installment_payment_price_cents(1000)
        expect(installment_1).to eq(334)

        # Seller changes to 2 installments (would be $5 each if not protected)
        installment_plan.update!(number_of_installments: 2)

        # Create subsequent purchases
        purchase_2 = create(:purchase, link: product, subscription:, is_installment_payment: true)
        purchase_3 = create(:purchase, link: product, subscription:, is_installment_payment: true)

        installment_2 = purchase_2.calculate_installment_payment_price_cents(1000)
        installment_3 = purchase_3.calculate_installment_payment_price_cents(1000)

        # Verify customer still pays original amounts
        expect(installment_2).to eq(333)
        expect(installment_3).to eq(333)

        # Verify total is correct
        total = installment_1 + installment_2 + installment_3
        expect(total).to eq(1000)
      end

      it "handles recurrence changes correctly" do
        purchase = create(:purchase,
                          link: product,
                          is_installment_payment: true,
                          price_cents: 334)
        subscription = purchase.subscription

        subscription.payment_options.create!(
          price: product.default_price,
          installment_plan:,
          number_of_installments: 3,
          recurrence: "monthly"
        )

        # Seller changes recurrence from monthly to weekly
        installment_plan.update!(recurrence: "weekly")

        # Config should still show monthly
        config = purchase.frozen_installment_config
        expect(config.recurrence).to eq("monthly")
      end
    end

    context "new customers after config change" do
      it "get the new configuration" do
        # Seller changes to 2 installments BEFORE customer purchases
        installment_plan.update!(number_of_installments: 2)

        # New customer makes purchase
        new_purchase = create(:purchase,
                              link: product,
                              is_installment_payment: true,
                              price_cents: 500)
        new_subscription = new_purchase.subscription

        new_subscription.payment_options.create!(
          price: product.default_price,
          installment_plan:,
          number_of_installments: 2,
          recurrence: "monthly"
        )

        # Should use NEW config (2 installments)
        expect(new_purchase.calculate_installment_payment_price_cents(1000)).to eq(500)
        expect(new_purchase.frozen_installment_config.number_of_installments).to eq(2)
      end
    end
  end
end
