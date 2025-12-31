# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillPaymentOptionInstallmentSnapshots do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 14700) }
  let(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 3, recurrence: "monthly") }
  let(:subscription) { create(:subscription, link: product, user: seller) }

  let(:offer_code) do
    create(:percentage_offer_code,
           user: seller,
           products: [product],
           code: "SAVE20",
           amount_percentage: 20,
           duration_in_months: 6)
  end

  describe ".perform" do
    context "when payment_option has installment plan but no snapshot" do
      it "creates snapshot with correct attributes" do
        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)
        original_purchase = build(:purchase,
                                  link: product,
                                  subscription: subscription,
                                  is_original_subscription_purchase: true,
                                  is_installment_payment: true,
                                  price_cents: 4900)
        original_purchase.save!(validate: false)

        second_purchase = build(:purchase, link: product, subscription: subscription, is_installment_payment: true, price_cents: 4900, installment_plan: installment_plan)
        second_purchase.save!(validate: false)

        expect(payment_option.installment_plan_snapshot).to be_nil

        described_class.perform

        snapshot = payment_option.reload.installment_plan_snapshot
        expect(snapshot).to be_present
        expect(snapshot.number_of_installments).to eq(3)
        expect(snapshot.recurrence).to eq("monthly")
        expect(snapshot.total_price_cents).to eq(14700)
      end

      it "captures offer code when original purchase had one" do
        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)
        original_purchase = build(:purchase,
                                  link: product,
                                  subscription: subscription,
                                  is_original_subscription_purchase: true,
                                  is_installment_payment: true,
                                  price_cents: 4900,
                                  offer_code: offer_code)
        original_purchase.save!(validate: false)

        second_purchase = build(:purchase,
                                link: product,
                                subscription: subscription,
                                is_installment_payment: true,
                                price_cents: 4900,
                                installment_plan: installment_plan)
        second_purchase.save!(validate: false)

        described_class.perform

        snapshot = payment_option.reload.installment_plan_snapshot
        expect(snapshot).to be_present
        expect(snapshot.has_locked_offer_code?).to be true
        expect(snapshot.locked_offer_code_code).to eq("SAVE20")
        expect(snapshot.locked_discount_percentage).to eq(20)
        expect(snapshot.locked_offer_code_duration_in_months).to eq(6)
      end

      it "creates snapshot without offer code when none was used" do
        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)
        original_purchase = build(:purchase,
                                  link: product,
                                  subscription: subscription,
                                  is_original_subscription_purchase: true,
                                  is_installment_payment: true,
                                  price_cents: 4900,
                                  offer_code: nil)
        original_purchase.save!(validate: false)

        second_purchase = build(:purchase,
                                link: product,
                                subscription: subscription,
                                is_installment_payment: true,
                                price_cents: 4900,
                                installment_plan: installment_plan)
        second_purchase.save!(validate: false)

        described_class.perform

        snapshot = payment_option.reload.installment_plan_snapshot
        expect(snapshot).to be_present
        expect(snapshot.has_locked_offer_code?).to be false
      end
    end

    context "when payment_option already has snapshot" do
      it "skips creating duplicate snapshot" do
        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)
        original_snapshot = create(:installment_plan_snapshot,
                                   payment_option: payment_option,
                                   number_of_installments: 3,
                                   recurrence: "monthly",
                                   total_price_cents: 14700)

        expect do
          described_class.perform
        end.not_to change { InstallmentPlanSnapshot.count }

        expect(payment_option.reload.installment_plan_snapshot).to eq(original_snapshot)
      end
    end

    context "when payment_option has no installment plan" do
      it "skips creating snapshot" do
        regular_subscription = create(:subscription, is_installment_plan: false)
        payment_option = create(:payment_option, subscription: regular_subscription, installment_plan: nil)

        expect do
          described_class.perform
        end.not_to change { InstallmentPlanSnapshot.count }

        expect(payment_option.reload.installment_plan_snapshot).to be_nil
      end
    end

    context "when subscription has no original purchase" do
      it "skips creating snapshot" do
        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)

        subscription.purchases.destroy_all

        expect do
          described_class.perform
        end.not_to change { InstallmentPlanSnapshot.count }

        expect(payment_option.reload.installment_plan_snapshot).to be_nil
      end
    end

    context "when error occurs during processing" do
      it "handles errors gracefully and continues processing" do
        subscription1 = create(:subscription, link: product, user: seller)
        payment_option1 = create(:payment_option, subscription: subscription1, installment_plan: installment_plan)
        purchase1 = build(:purchase, link: product, subscription: subscription1, is_original_subscription_purchase: true, is_installment_payment: true, price_cents: 4900)
        purchase1.save!(validate: false)
        purchase1_2 = build(:purchase, link: product, subscription: subscription1, is_installment_payment: true, price_cents: 4900, installment_plan: installment_plan)
        purchase1_2.save!(validate: false)

        subscription2 = create(:subscription, link: product, user: seller)
        payment_option2 = create(:payment_option, subscription: subscription2, installment_plan: installment_plan)
        purchase2 = build(:purchase, link: product, subscription: subscription2, is_original_subscription_purchase: true, is_installment_payment: true, price_cents: 4900)
        purchase2.save!(validate: false)
        purchase2_2 = build(:purchase, link: product, subscription: subscription2, is_installment_payment: true, price_cents: 4900, installment_plan: installment_plan)
        purchase2_2.save!(validate: false)

        call_count = 0
        allow_any_instance_of(InstallmentPlanSnapshot).to receive(:save!) do |snapshot|
          call_count += 1
          if snapshot.payment_option_id == payment_option1.id
            raise StandardError.new("Test error")
          else
            snapshot.save(validate: false) || raise(ActiveRecord::RecordInvalid.new(snapshot))
          end
        end

        expect(Rails.logger).to receive(:error).with(/Failed to backfill PaymentOption #{payment_option1.id}/)

        described_class.perform

        expect(payment_option1.reload.installment_plan_snapshot).to be_nil
        expect(payment_option2.reload.installment_plan_snapshot).to be_present
      end
    end

    context "when processing multiple payment_options" do
      it "creates snapshots for all eligible payment_options" do
        payment_options = 3.times.map do |i|
          sub = create(:subscription, link: product, user: seller)
          payment_option = create(:payment_option, subscription: sub, installment_plan: installment_plan)
          purchase = build(:purchase, link: product, subscription: sub, is_original_subscription_purchase: true, is_installment_payment: true, price_cents: 4900)
          purchase.save!(validate: false)
          purchase2 = build(:purchase, link: product, subscription: sub, is_installment_payment: true, price_cents: 4900, installment_plan: installment_plan)
          purchase2.save!(validate: false)
          payment_option
        end

        expect do
          described_class.perform
        end.to change { InstallmentPlanSnapshot.count }.by(3)

        payment_options.each do |payment_option|
          snapshot = payment_option.reload.installment_plan_snapshot
          expect(snapshot).to be_present
          expect(snapshot.number_of_installments).to eq(3)
          expect(snapshot.recurrence).to eq("monthly")
          expect(snapshot.total_price_cents).to eq(14700)
        end
      end
    end

    context "when deriving price from payment history" do
      it "calculates total from completed installments" do
        original_purchase = build(:purchase, link: product, subscription: subscription, is_original_subscription_purchase: true, is_installment_payment: true, price_cents: 5000, installment_plan: installment_plan)
        original_purchase.save!(validate: false)

        second_purchase = build(:purchase, link: product, subscription: subscription, is_installment_payment: true, price_cents: 4900, installment_plan: installment_plan)
        second_purchase.save!(validate: false)

        third_purchase = build(:purchase, link: product, subscription: subscription, is_installment_payment: true, price_cents: 4900, installment_plan: installment_plan)
        third_purchase.save!(validate: false)

        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)

        described_class.perform

        snapshot = payment_option.reload.installment_plan_snapshot
        expect(snapshot.total_price_cents).to eq(14800)
      end

      it "extrapolates total from partial payment history" do
        original_purchase = build(:purchase, link: product, subscription: subscription, is_original_subscription_purchase: true, is_installment_payment: true, price_cents: 5000, installment_plan: installment_plan)
        original_purchase.save!(validate: false)

        second_purchase = build(:purchase, link: product, subscription: subscription, is_installment_payment: true, price_cents: 5000, installment_plan: installment_plan)
        second_purchase.save!(validate: false)

        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)

        described_class.perform

        snapshot = payment_option.reload.installment_plan_snapshot
        expect(snapshot.total_price_cents).to eq(15000)
      end

      it "skips when only one payment exists" do
        original_purchase = build(:purchase, link: product, subscription: subscription, is_original_subscription_purchase: true, is_installment_payment: true, price_cents: 14700, installment_plan: installment_plan)
        original_purchase.save!(validate: false)

        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)

        expect(Rails.logger).to receive(:info).with(/insufficient payment history/)

        described_class.perform

        expect(payment_option.reload.installment_plan_snapshot).to be_nil
      end

      it "reverse-engineers total from first two payments" do
        original_purchase = build(:purchase, link: product, subscription: subscription, is_original_subscription_purchase: true, is_installment_payment: true, price_cents: 4900, installment_plan: installment_plan)
        original_purchase.save!(validate: false)

        product.update!(price_cents: 19700)

        second_purchase = build(:purchase, link: product, subscription: subscription, is_installment_payment: true, price_cents: 4900, installment_plan: installment_plan)
        second_purchase.save!(validate: false)

        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)

        described_class.perform

        snapshot = payment_option.reload.installment_plan_snapshot
        expect(snapshot.total_price_cents).to eq(14700)
      end

      it "skips when price changed between first and second payment" do
        original_purchase = build(:purchase, link: product, subscription: subscription, is_original_subscription_purchase: true, is_installment_payment: true, price_cents: 5000, installment_plan: installment_plan)
        original_purchase.save!(validate: false)

        product.update!(price_cents: 19700)

        second_purchase = build(:purchase, link: product, subscription: subscription, is_installment_payment: true, price_cents: 6567, installment_plan: installment_plan)
        second_purchase.save!(validate: false)

        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)

        expect(Rails.logger).to receive(:warn).with(/price likely changed mid-subscription/)

        described_class.perform

        expect(payment_option.reload.installment_plan_snapshot).to be_nil
      end
    end
  end
end
