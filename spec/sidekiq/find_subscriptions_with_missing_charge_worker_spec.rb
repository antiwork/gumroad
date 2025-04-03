# frozen_string_literal: true

require "spec_helper"

describe FindSubscriptionsWithMissingChargeWorker do
  describe "#perform" do
    before do
      described_class.jobs.clear
      RecurringChargeWorker.jobs.clear
    end

    context "without a batch_number" do
      it "queues a job for each of the 10 batches" do
        freeze_time
        described_class.new.perform
        expect(described_class.jobs.size).to eq(10)
        expect(described_class).to have_enqueued_sidekiq_job(0)
        expect(described_class).to have_enqueued_sidekiq_job(1).in(20.minutes)
        expect(described_class).to have_enqueued_sidekiq_job(4).in(80.minutes)
        expect(described_class).to have_enqueued_sidekiq_job(9).in(180.minutes)
      end
    end

    context "with a batch_number" do
      before do
        @product = create(:membership_product_with_preset_tiered_pricing)
        @subscription = create(:subscription, link: @product, id: 1_000)
        @initial_purchase_time = Time.utc(2020, 1, 1)
        @six_months_after_purchase = Time.utc(2020, 6, 2)
        price_cents = @product.default_tier.prices.first.price_cents
        create(:membership_purchase, subscription: @subscription, succeeded_at: @initial_purchase_time,
                                     price_cents:)
      end

      context "not matching a subscription id" do
        before do
          @batch_number = 1
        end

        it "does not queue overdue subscriptions with the wrong id" do
          travel_to @six_months_after_purchase do
            described_class.new.perform(@batch_number)

            expect(RecurringChargeWorker.jobs.size).to eq(0)
          end
        end
      end

      context "matching a subscription id" do
        before do
          @batch_number = 0
        end

        it "queues subscriptions according to last charge's date" do
          travel_to @six_months_after_purchase do
            described_class.new.perform(@batch_number)

            expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id, true)
          end
        end

        it "does not queue subscriptions that are not overdue for a charge" do
          travel_to @initial_purchase_time + 15.days do
            described_class.new.perform(@batch_number)

            expect(RecurringChargeWorker.jobs.size).to eq(0)
          end
        end

        it "does not queue subscriptions that are less than 75 minutes overdue for a charge" do
          subscription_end_time = @initial_purchase_time + @subscription.period

          travel_to subscription_end_time + 74.minutes do
            described_class.new.perform(@batch_number)

            expect(RecurringChargeWorker.jobs.size).to eq(0)
          end

          travel_to subscription_end_time + 76.minutes do
            described_class.new.perform(@batch_number)

            expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id, true)
          end
        end

        it "does not queue free subscriptions" do
          travel_to @six_months_after_purchase do
            @subscription.original_purchase.update_columns(price_cents: 0, displayed_price_cents: 0)
            described_class.new.perform(@batch_number)

            expect(RecurringChargeWorker.jobs.size).to eq(0)
          end
        end

        it "queues subscriptions that were discounted to free with an elapsed discount" do
          offer_code = create(:offer_code, products: [@product], duration_in_months: 1, amount_cents: @product.price_cents)
          original_purchase = @subscription.original_purchase
          original_purchase.update_columns(offer_code_id: offer_code.id, displayed_price_cents: 0, price_cents: 0)
          original_purchase.create_purchase_offer_code_discount(offer_code:, offer_code_amount: @product.default_tier.prices.first.price_cents, offer_code_is_percent: false, pre_discount_minimum_price_cents: @product.default_tier.prices.first.price_cents, duration_in_billing_cycles: 1)

          described_class.new.perform(@batch_number)
          expect(RecurringChargeWorker.jobs.size).to eq(1)
        end

        it "does not queue subscriptions to products from suspended users" do
          travel_to @six_months_after_purchase do
            @subscription.link.user.update!(user_risk_state: "suspended_for_fraud")
            described_class.new.perform(@batch_number)

            expect(RecurringChargeWorker.jobs.size).to eq(0)
          end
        end

        it "does not queue subscriptions that already have a charge in progress" do
          travel_to @six_months_after_purchase do
            create(:recurring_membership_purchase, subscription: @subscription, purchase_state: "in_progress")
            described_class.new.perform(@batch_number)

            expect(RecurringChargeWorker.jobs.size).to eq(0)
          end
        end
      end
    end
  end
end
