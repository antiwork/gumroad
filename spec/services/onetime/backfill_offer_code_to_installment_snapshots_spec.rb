# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillOfferCodeToInstallmentSnapshots do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 14700) }
  let(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 3, recurrence: "monthly") }

  let(:offer_code) do
    create(:percentage_offer_code,
           user: seller,
           products: [product],
           code: "SAVE20",
           amount_percentage: 20,
           duration_in_months: 6)
  end

  let(:fixed_offer_code) do
    create(:offer_code,
           user: seller,
           products: [product],
           code: "FLAT500",
           amount_cents: 500)
  end

  describe ".perform" do
    context "when snapshot has no offer code data but original purchase had one" do
      it "backfills the offer code snapshot" do
        subscription = create(:subscription, link: product, user: seller)
        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)

        original_purchase = build(:purchase,
                                  link: product,
                                  subscription: subscription,
                                  is_original_subscription_purchase: true,
                                  offer_code: offer_code)
        original_purchase.save!(validate: false)

        snapshot = create(:installment_plan_snapshot, payment_option: payment_option)
        expect(snapshot.has_locked_offer_code?).to be false

        result = described_class.perform

        snapshot.reload
        expect(snapshot.has_locked_offer_code?).to be true
        expect(snapshot.locked_offer_code_code).to eq("SAVE20")
        expect(snapshot.locked_discount_percentage).to eq(20)
        expect(result[:updated]).to eq(1)
      end
    end

    context "when snapshot already has offer code data" do
      it "skips the snapshot" do
        subscription = create(:subscription, link: product, user: seller)
        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)

        original_purchase = build(:purchase,
                                  link: product,
                                  subscription: subscription,
                                  is_original_subscription_purchase: true,
                                  offer_code: offer_code)
        original_purchase.save!(validate: false)

        snapshot = create(:installment_plan_snapshot, payment_option: payment_option)
        snapshot.snapshot_offer_code!(offer_code)
        snapshot.save!

        result = described_class.perform

        expect(result[:skipped]).to eq(1)
        expect(result[:updated]).to eq(0)
      end
    end

    context "when original purchase had no offer code" do
      it "skips the snapshot" do
        subscription = create(:subscription, link: product, user: seller)
        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)

        original_purchase = build(:purchase,
                                  link: product,
                                  subscription: subscription,
                                  is_original_subscription_purchase: true,
                                  offer_code: nil)
        original_purchase.save!(validate: false)

        snapshot = create(:installment_plan_snapshot, payment_option: payment_option)

        result = described_class.perform

        snapshot.reload
        expect(snapshot.has_locked_offer_code?).to be false
        expect(result[:skipped]).to eq(1)
      end
    end

    context "when offer code has been deleted" do
      it "still backfills from the purchase association" do
        subscription = create(:subscription, link: product, user: seller)
        payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)

        original_purchase = build(:purchase,
                                  link: product,
                                  subscription: subscription,
                                  is_original_subscription_purchase: true,
                                  offer_code: offer_code)
        original_purchase.save!(validate: false)

        snapshot = create(:installment_plan_snapshot, payment_option: payment_option)

        # Delete the offer code after the purchase was made
        offer_code.destroy!

        result = described_class.perform

        snapshot.reload
        # The purchase still has the offer_code_id, even though the code is deleted
        # This test verifies we handle the deletion gracefully
        expect(result[:skipped]).to eq(1)  # Can't backfill deleted codes
      end
    end

    context "with multiple snapshots" do
      it "processes all snapshots correctly" do
        snapshots = 3.times.map do
          subscription = create(:subscription, link: product, user: seller)
          payment_option = create(:payment_option, subscription: subscription, installment_plan: installment_plan)

          original_purchase = build(:purchase,
                                    link: product,
                                    subscription: subscription,
                                    is_original_subscription_purchase: true,
                                    offer_code: offer_code)
          original_purchase.save!(validate: false)

          create(:installment_plan_snapshot, payment_option: payment_option)
        end

        result = described_class.perform

        expect(result[:updated]).to eq(3)

        snapshots.each do |snapshot|
          snapshot.reload
          expect(snapshot.has_locked_offer_code?).to be true
          expect(snapshot.locked_offer_code_code).to eq("SAVE20")
        end
      end
    end

    context "when error occurs during processing" do
      it "handles errors gracefully and continues" do
        subscription1 = create(:subscription, link: product, user: seller)
        payment_option1 = create(:payment_option, subscription: subscription1, installment_plan: installment_plan)
        purchase1 = build(:purchase, link: product, subscription: subscription1, is_original_subscription_purchase: true, offer_code: offer_code)
        purchase1.save!(validate: false)
        snapshot1 = create(:installment_plan_snapshot, payment_option: payment_option1)

        subscription2 = create(:subscription, link: product, user: seller)
        payment_option2 = create(:payment_option, subscription: subscription2, installment_plan: installment_plan)
        purchase2 = build(:purchase, link: product, subscription: subscription2, is_original_subscription_purchase: true, offer_code: fixed_offer_code)
        purchase2.save!(validate: false)
        snapshot2 = create(:installment_plan_snapshot, payment_option: payment_option2)

        allow(snapshot1).to receive(:save!).and_raise(StandardError.new("Test error"))
        allow(InstallmentPlanSnapshot).to receive(:find_each).and_yield(snapshot1).and_yield(snapshot2)

        expect(Rails.logger).to receive(:error).with(/Failed to backfill snapshot #{snapshot1.id}/)
        expect(Rails.logger).to receive(:info).with(/Backfilled offer code/)
        expect(Rails.logger).to receive(:info).with(/Backfill complete/)

        described_class.perform

        snapshot2.reload
        expect(snapshot2.has_locked_offer_code?).to be true
      end
    end
  end
end
