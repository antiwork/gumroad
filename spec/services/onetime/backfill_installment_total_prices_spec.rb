# frozen_string_literal: true

require "spec_helper"

RSpec.describe Onetime::BackfillInstallmentTotalPrices do
  let(:service) { described_class.new(dry_run: true, batch_size: 10) }
  let(:seller) { create(:user) }
  let(:purchaser) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 9003) }
  let(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 9, recurrence: "monthly") }

  before do
    product.update!(installment_plan: installment_plan)
  end

  describe "#perform" do
    context "original purchase creation" do
      it "sets total_price_before_installments_cents on the first installment purchase" do
        subscription = create(:subscription, link: product, user: purchaser, is_installment_plan: true)
        original = create(:installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)

        expect(original.total_price_before_installments_cents).to eq(9003)
      end
    end
    context "with no eligible subscriptions" do
      it "processes zero subscriptions" do
        service.process
        expect(service.stats[:total_processed]).to eq(0)
      end
    end

    context "with eligible subscriptions" do
      let!(:purchase) do
        p = create(:installment_plan_purchase, link: product, purchaser: purchaser, purchase_state: :successful)
        # Unset total_price_before_installments_cents to simulate missing data that needs backfilling
        p.update_column(:json_data, p.json_data.except("total_price_before_installments_cents"))
        p.reload
      end
      let(:subscription) { purchase.subscription }

      context "Strategy 1: two successful payments" do
        let!(:recurring_purchase) do
          # Create recurring purchase BEFORE unsetting total_price_before_installments_cents
          # so it uses correct calculation. In reality, recurring purchases are created
          # after original purchase already has total_price_before_installments_cents set.
          create(:recurring_installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)
        end

        it "backfills using Strategy 1" do
          original_purchase = subscription.original_purchase
          expect(original_purchase.total_price_before_installments_cents).to be_nil

          service.process
          expect(service.stats[:total_processed]).to eq(1)
          expect(service.stats[:backfilled_strategy_1]).to eq(1)
          expect(service.stats[:backfilled_strategy_2]).to eq(0)
          expect(original_purchase.reload.total_price_before_installments_cents).to be_nil
          result = service.send(:derive_total_from_purchases, subscription)
          expect(result[:total]).to eq(9003)
        end

        it "calculates the correct total" do
          result = service.send(:derive_total_from_purchases, subscription)
          expect(result[:total]).to be_present
          expect(result[:strategy]).to eq(1)
          first = result[:first_payment]
          second = result[:second_payment]
          count = result[:count]
          remainder = result[:remainder]
          expect(remainder).to eq(first - second)
          expect(result[:total]).to eq(second * count + remainder)
        end

        context "when not in dry_run mode" do
          let(:service) { described_class.new(dry_run: false, batch_size: 10) }

          it "updates the original purchase" do
            original_purchase = subscription.original_purchase
            expect(original_purchase.total_price_before_installments_cents).to be_nil
            initial_count = service.stats[:total_processed]
            service.process
            expect(service.stats[:total_processed]).to be > initial_count
            expect(original_purchase.reload.total_price_before_installments_cents).to eq(9003)
          end
        end
      end

      context "Strategy 2: single payment with no plan/price changes" do
        it "backfills using Strategy 2" do
          original_purchase = subscription.original_purchase
          expect(original_purchase.total_price_before_installments_cents).to be_nil

          service.process

          expect(service.stats[:total_processed]).to eq(1)
          expect(service.stats[:backfilled_strategy_1]).to eq(0)
          expect(service.stats[:backfilled_strategy_2]).to eq(1)
          expect(original_purchase.reload.total_price_before_installments_cents).to be_nil
          result = service.send(:derive_total_from_purchases, subscription)
          expect(result[:total]).to eq(9003)
        end

        it "calculates the correct total" do
          result = service.send(:derive_total_from_purchases, subscription)
          expect(result[:total]).to be_present
          expect(result[:strategy]).to eq(2)
          expect(result[:first_payment]).to be_present
          expect(result[:expected_second]).to be_present
          expect(result[:remainder]).to be_present
          expect(result[:warning]).to be_present

          expect(result[:remainder]).to eq(result[:first_payment] - result[:expected_second])
          expect(result[:total]).to eq(result[:expected_second] * result[:count] + result[:remainder])
        end

        context "when not in dry_run mode" do
          let(:service) { described_class.new(dry_run: false, batch_size: 10) }

          it "updates the original purchase" do
            original_purchase = subscription.original_purchase
            expect(original_purchase.total_price_before_installments_cents).to be_nil

            initial_count = service.stats[:total_processed]
            service.process

            expect(service.stats[:total_processed]).to be > initial_count
            expect(original_purchase.reload.total_price_before_installments_cents).to eq(9003)
          end
        end
      end

      context "when plan has changed" do
        before do
          installment_plan.update!(deleted_at: Time.current)
          new_plan = create(:product_installment_plan, link: product, number_of_installments: 12, recurrence: "monthly")
          product.update!(installment_plan: new_plan)
        end

        it "skips the subscription" do
          service.process

          expect(service.stats[:total_processed]).to eq(1)
          expect(service.stats[:backfilled_strategy_1]).to eq(0)
          expect(service.stats[:backfilled_strategy_2]).to eq(0)
          expect(service.stats[:skipped_plan_changed]).to eq(1)
        end

        it "returns nil with reason" do
          result = service.send(:derive_total_from_purchases, subscription)

          expect(result[:total]).to be_nil
          expect(result[:strategy]).to eq(2)
          expect(result[:reason]).to include("Plan changed")
        end
      end

      context "when price has changed" do
        before do
          product.update!(price_cents: 18000)
        end

        it "skips the subscription" do
          service.process

          expect(service.stats[:total_processed]).to eq(1)
          expect(service.stats[:backfilled_strategy_1]).to eq(0)
          expect(service.stats[:backfilled_strategy_2]).to eq(0)
          expect(service.stats[:skipped_price_changed]).to eq(1)
        end

        it "returns nil with reason" do
          result = service.send(:derive_total_from_purchases, subscription)

          expect(result[:total]).to be_nil
          expect(result[:strategy]).to eq(2)
          expect(result[:reason]).to include("Price changed")
        end
      end

      context "when remainder is invalid" do
        before do
          subscription.purchases.first.update_column(:displayed_price_cents, 500)
        end

        it "skips the subscription" do
          service.process

          expect(service.stats[:total_processed]).to eq(1)
          expect(service.stats[:backfilled_strategy_1]).to eq(0)
          expect(service.stats[:backfilled_strategy_2]).to eq(0)
          expect(service.stats[:skipped_invalid_remainder] + service.stats[:skipped_price_changed]).to eq(1)
        end

        it "returns nil with reason" do
          result = service.send(:derive_total_from_purchases, subscription)

          expect(result[:total]).to be_nil
          expect(result[:strategy]).to eq(2)
          expect(result[:reason]).to match(/Invalid remainder|Price changed/)
        end
      end
    end

    context "with already backfilled subscription" do
      let!(:subscription) do
        create(:subscription, link: product, user: purchaser, is_installment_plan: true)
      end

      before do
        p = create(:installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)
        p.update_column(:json_data, p.json_data.merge("total_price_before_installments_cents" => 9000)) # already has value
      end

      it "skips already backfilled subscriptions" do
        service.process
        expect(service.stats[:total_processed]).to eq(0)
      end
    end

    context "with inactive subscription" do
      let!(:subscription) do
        create(:subscription, link: product, user: purchaser, is_installment_plan: true, ended_at: 1.day.ago)
      end

      it "skips inactive subscriptions" do
        service.process

        expect(service.stats[:total_processed]).to eq(0)
      end
    end
  end

  describe "#attempt_strategy_1" do
    let(:subscription) do
      create(:subscription, link: product, user: purchaser, is_installment_plan: true)
    end

    context "with valid two payments" do
      before do
        create(:installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)
        create(:recurring_installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)
      end

      it "returns the correct total" do
        result = service.send(:attempt_strategy_1, subscription)

        expect(result[:total]).to be_present
        expect(result[:strategy]).to eq(1)
        expect(result[:first_payment]).to be_present
        expect(result[:second_payment]).to be_present
        expect(result[:count]).to eq(9)
        expect(result[:remainder]).to eq(result[:first_payment] - result[:second_payment])

        expect(result[:total]).to eq(result[:second_payment] * result[:count] + result[:remainder])
      end
    end

    context "with only one payment" do
      before do
        create(:installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)
      end

      it "returns nil with reason" do
        result = service.send(:attempt_strategy_1, subscription)

        expect(result[:total]).to be_nil
        expect(result[:strategy]).to eq(1)
        expect(result[:reason]).to eq("Only 1 payment(s) made")
      end
    end

    context "with invalid remainder (negative)" do
      before do
        create(:installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)

        subscription.purchases.order(:created_at).first.update_column(:displayed_price_cents, 500)
        create(:recurring_installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)
      end

      it "returns nil with reason" do
        result = service.send(:attempt_strategy_1, subscription)

        expect(result[:total]).to be_nil
        expect(result[:strategy]).to eq(1)
        expect(result[:reason]).to include("Invalid remainder -500")
      end
    end

    context "with invalid remainder (>= count)" do
      before do
        create(:installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)
        create(:recurring_installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)
        # Force invalid remainder >= count by raising first purchase amount
        plan = subscription.payment_options.first.installment_plan
        base = product.price_cents / plan.number_of_installments
        # Set first_payment to base + count + 1 to get remainder = 10
        subscription.purchases.order(:created_at).first.update_column(:displayed_price_cents, base + plan.number_of_installments + 1)
      end

      it "returns nil with reason" do
        result = service.send(:attempt_strategy_1, subscription)

        expect(result[:total]).to be_nil
        expect(result[:strategy]).to eq(1)
        expect(result[:reason]).to include("Invalid remainder 10")
      end
    end
  end

  describe "#attempt_strategy_2" do
    let(:subscription) do
      create(:subscription, link: product, user: purchaser, is_installment_plan: true)
    end

    context "with single payment and no changes" do
      before do
        create(:installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)
      end

      it "returns the correct total" do
        result = service.send(:attempt_strategy_2, subscription)

        expect(result[:total]).to be_present
        expect(result[:strategy]).to eq(2)
        expect(result[:first_payment]).to be_present
        expect(result[:expected_second]).to be_present
        expect(result[:count]).to eq(9)
        expect(result[:remainder]).to be_present
        expect(result[:warning]).to be_present

        # Verify the math works
        expect(result[:remainder]).to eq(result[:first_payment] - result[:expected_second])
        expect(result[:total]).to eq(result[:expected_second] * result[:count] + result[:remainder])
      end
    end

    context "with plan changed" do
      before do
        create(:installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)

        # Change the plan
        installment_plan.update!(deleted_at: Time.current)
        new_plan = create(:product_installment_plan, link: product, number_of_installments: 12, recurrence: "monthly")
        product.update!(installment_plan: new_plan)
      end

      it "returns nil with reason" do
        result = service.send(:attempt_strategy_2, subscription)

        expect(result[:total]).to be_nil
        expect(result[:strategy]).to eq(2)
        expect(result[:reason]).to include("Plan changed")
      end
    end

    context "with price changed" do
      before do
        create(:purchase, link: product, purchaser: purchaser, subscription: subscription, is_original_subscription_purchase: true, purchase_state: :successful, displayed_price_cents: 1002)

        product.update!(price_cents: 18000)
      end

      it "returns nil with reason" do
        result = service.send(:attempt_strategy_2, subscription)

        expect(result[:total]).to be_nil
        expect(result[:strategy]).to eq(2)
        expect(result[:reason]).to include("Price changed")
      end
    end

    context "with two payments" do
      before do
        create(:installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)
        create(:recurring_installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)
      end

      it "returns nil with reason (expects exactly 1 payment)" do
        result = service.send(:attempt_strategy_2, subscription)

        expect(result[:total]).to be_nil
        expect(result[:strategy]).to eq(2)
        expect(result[:reason]).to eq("Expected 1 payment, found 2")
      end
    end
  end

  describe "edge cases" do
    context "with different installment counts" do
      [3, 5, 9, 12].each do |count|
        context "with #{count} installments" do
          let(:total_price) { 10000 }
          let(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: count, recurrence: "monthly") }

          before do
            product.update!(price_cents: total_price, installment_plan: installment_plan)
          end

          it "correctly calculates total from two payments" do
            subscription = create(:subscription, link: product, user: purchaser, is_installment_plan: true)
            remainder = total_price % count

            create(:installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)
            create(:recurring_installment_plan_purchase, link: product, purchaser: purchaser, subscription: subscription, purchase_state: :successful)

            result = service.send(:attempt_strategy_1, subscription)

            expect(result[:total]).to eq(total_price)
            expect(result[:remainder]).to eq(remainder)
          end
        end
      end
    end

    context "with no payment_option" do
      let(:subscription) do
        sub = create(:subscription, link: product, user: purchaser, is_installment_plan: true)
        create(:installment_plan_purchase, link: product, purchaser: purchaser, subscription: sub, purchase_state: :successful)
        create(:recurring_installment_plan_purchase, link: product, purchaser: purchaser, subscription: sub, purchase_state: :successful)
        sub.payment_options.destroy_all
        sub.reload
      end

      it "returns nil with reason" do
        result = service.send(:attempt_strategy_1, subscription)

        expect(result[:total]).to be_nil
        expect(result[:reason]).to include("No installment plan found")
      end
    end
  end
end
