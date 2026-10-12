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

        context "when a restart notice is still owed" do
          before { DeliverIndianCardMandateRestartNoticesJob.jobs.clear }

          it "re-enqueues its delivery for a live membership" do
            @subscription.update!(indian_card_mandate_restart_completed_notice_pending: true)

            described_class.new.perform(@batch_number)

            expect(DeliverIndianCardMandateRestartNoticesJob.jobs.map { _1["args"] }).to eq([[@subscription.id]])
          end

          it "re-enqueues an abandonment notice owed on an ended membership" do
            @subscription.update!(ended_at: 1.day.ago, deactivated_at: 1.day.ago, indian_card_mandate_restart_abandoned_notice_pending: true)

            described_class.new.perform(@batch_number)

            expect(DeliverIndianCardMandateRestartNoticesJob.jobs.map { _1["args"] }).to eq([[@subscription.id]])
          end

          it "re-enqueues an abandonment notice owed on a deactivated membership" do
            @subscription.update!(deactivated_at: 1.day.ago, indian_card_mandate_restart_abandoned_notice_pending: true)

            described_class.new.perform(@batch_number)

            expect(DeliverIndianCardMandateRestartNoticesJob.jobs.map { _1["args"] }).to eq([[@subscription.id]])
          end

          it "leaves a notice owed in another batch to that batch" do
            @subscription.update!(deactivated_at: 1.day.ago, indian_card_mandate_restart_abandoned_notice_pending: true)

            described_class.new.perform(1)

            expect(DeliverIndianCardMandateRestartNoticesJob.jobs.size).to eq(0)
          end

          it "enqueues nothing for a deactivated membership with no notice owed" do
            @subscription.update!(deactivated_at: 1.day.ago, indian_card_mandate_restart_held: true)

            described_class.new.perform(@batch_number)

            expect(DeliverIndianCardMandateRestartNoticesJob.jobs.size).to eq(0)
          end

          it "finds the owed notices through the indexed column, not by scanning the flag bits" do
            @subscription.update!(deactivated_at: 1.day.ago, indian_card_mandate_restart_abandoned_notice_pending: true)
            queries = []
            callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("subscriptions.id % 10") }

            ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
              described_class.new.perform(@batch_number)
            end

            notice_query = queries.find { _1.include?("indian_card_mandate_restart_notice_owed") }
            expect(notice_query).to include("`subscriptions`.`indian_card_mandate_restart_notice_owed` = TRUE").or include("`subscriptions`.`indian_card_mandate_restart_notice_owed` = 1")
            expect(notice_query).not_to include("flags &")
          end

          it "keeps a notice owed while only one of two markers has been delivered" do
            @subscription.update!(
              deactivated_at: 1.day.ago,
              indian_card_mandate_restart_abandoned_notice_pending: true,
              indian_card_mandate_restart_completed_notice_pending: true
            )
            @subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: false)

            described_class.new.perform(@batch_number)

            expect(DeliverIndianCardMandateRestartNoticesJob.jobs.map { _1["args"] }).to eq([[@subscription.id]])
          end

          it "stops re-enqueuing once every marker has been delivered" do
            @subscription.update!(deactivated_at: 1.day.ago, indian_card_mandate_restart_abandoned_notice_pending: true)
            allow(CustomerLowPriorityMailer).to receive_message_chain(:subscription_indian_card_mandate_invalid, :deliver_later)

            described_class.new.perform(@batch_number)
            DeliverIndianCardMandateRestartNoticesJob.drain
            described_class.new.perform(@batch_number)

            expect(DeliverIndianCardMandateRestartNoticesJob.jobs.size).to eq(0)
          end

          context "when a notice has been owed past the retention window" do
            let(:retention) { Subscription::INDIAN_CARD_MANDATE_RESTART_NOTICE_RETENTION }

            before do
              allow(ErrorNotifier).to receive(:notify)
              travel_to(retention.ago - 2.days) do
                @subscription.update!(deactivated_at: 3.days.ago, indian_card_mandate_restart_abandoned_notice_pending: true)
              end
            end

            it "reports it once with its identifier and age, then clears everything so it cannot loop" do
              described_class.new.perform(@batch_number)
              described_class.new.perform(@batch_number)

              expect(DeliverIndianCardMandateRestartNoticesJob.jobs.size).to eq(0)
              expect(ErrorNotifier).to have_received(:notify)
                .with(a_string_including("past retention"), hash_including(subscription_id: @subscription.id, abandoned_notice: true, completed_notice: false, age_in_days: 9))
                .once
              @subscription.reload
              expect(@subscription).not_to be_indian_card_mandate_restart_abandoned_notice_pending
              expect(@subscription.indian_card_mandate_restart_notice_owed).to be(false)
              expect(@subscription.indian_card_mandate_restart_notice_recorded_at).to be_nil
            end

            it "still redrives a notice within the window in the same sweep" do
              fresh = create(:subscription, id: 1_010, deactivated_at: 1.day.ago, indian_card_mandate_restart_abandoned_notice_pending: true)

              described_class.new.perform(@batch_number)

              expect(DeliverIndianCardMandateRestartNoticesJob.jobs.map { _1["args"] }).to eq([[fresh.id]])
            end

            it "reports a stale notice it could not clear and still handles the others" do
              other_stale = create(:subscription, id: 1_020, deactivated_at: 3.days.ago)
              travel_to(retention.ago - 3.days) { other_stale.update!(indian_card_mandate_restart_abandoned_notice_pending: true) }
              error = ActiveRecord::Deadlocked.new("deadlock")
              allow_any_instance_of(Subscription).to receive(:expire_stale_indian_card_mandate_restart_notices!).and_wrap_original do |original|
                raise error if original.receiver.id == @subscription.id

                original.call
              end

              expect { described_class.new.perform(@batch_number) }.not_to raise_error

              expect(ErrorNotifier).to have_received(:notify).with(error, subscription_id: @subscription.id)
              expect(other_stale.reload.indian_card_mandate_restart_notice_owed).to be(false)
            end

            it "still schedules the overdue charge" do
              travel_to @six_months_after_purchase do
                @subscription.update!(deactivated_at: nil)
                described_class.new.perform(@batch_number)

                expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id, true)
              end
            end
          end

          it "enqueues nothing when no notice is owed" do
            described_class.new.perform(@batch_number)

            expect(DeliverIndianCardMandateRestartNoticesJob.jobs.size).to eq(0)
          end

          context "when enqueuing a notice fails" do
            let!(:failing_notice_subscription) { create(:subscription, id: 1_010, deactivated_at: 1.day.ago, indian_card_mandate_restart_abandoned_notice_pending: true) }
            let!(:other_notice_subscription) { create(:subscription, id: 1_020, deactivated_at: 1.day.ago, indian_card_mandate_restart_abandoned_notice_pending: true) }
            let(:error) { Redis::CannotConnectError.new("redis down") }

            before do
              allow(ErrorNotifier).to receive(:notify)
              allow(DeliverIndianCardMandateRestartNoticesJob).to receive(:perform_async).and_wrap_original do |original, id|
                raise error if id == failing_notice_subscription.id

                original.call(id)
              end
            end

            it "still schedules the overdue charge" do
              travel_to @six_months_after_purchase do
                expect { described_class.new.perform(@batch_number) }.not_to raise_error

                expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id, true)
              end
            end

            it "still hands a pending recovery to the mandate job" do
              CompleteIndianCardMandateJob.jobs.clear
              @subscription.update!(indian_card_mandate_recovery_pending: true)

              travel_to @six_months_after_purchase do
                expect { described_class.new.perform(@batch_number) }.not_to raise_error

                expect(CompleteIndianCardMandateJob.jobs.map { _1["args"] }).to eq([[@subscription.id]])
              end
            end

            it "reports the failure and still enqueues the other notices" do
              expect { described_class.new.perform(@batch_number) }.not_to raise_error

              expect(ErrorNotifier).to have_received(:notify).with(error, subscription_id: failing_notice_subscription.id)
              expect(DeliverIndianCardMandateRestartNoticesJob.jobs.map { _1["args"] }).to eq([[other_notice_subscription.id]])
            end
          end
        end

        context "when an Indian-mandate restart or recovery left its owed charge unqueued" do
          before do
            CompleteIndianCardMandateJob.jobs.clear
            @subscription.update!(indian_card_mandate_recovery_pending: true)
          end

          it "hands it back to the mandate job, which queues the charge once without ignoring the earlier failures" do
            travel_to @six_months_after_purchase do
              described_class.new.perform(@batch_number)

              expect(RecurringChargeWorker.jobs.size).to eq(0)
              expect(CompleteIndianCardMandateJob.jobs.map { _1["args"] }).to eq([[@subscription.id]])

              CompleteIndianCardMandateJob.drain

              expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[@subscription.id]])
              expect(@subscription.reload).not_to be_indian_card_mandate_recovery_pending

              described_class.new.perform(@batch_number)

              expect(CompleteIndianCardMandateJob.jobs.size).to eq(0)
            end
          end

          it "leaves it to the running chain while the renewal stop is still set" do
            @subscription.update!(renewal_disabled_due_to_indian_card_mandate: true)

            travel_to @six_months_after_purchase do
              described_class.new.perform(@batch_number)

              expect(CompleteIndianCardMandateJob.jobs.size).to eq(0)
              expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id, true)
            end
          end
        end

        context "when a restart owes a charge priced by its persisted context" do
          let(:buyer) { create(:user) }

          before do
            @subscription.update!(user: buyer)
            @subscription.original_purchase.update_columns(purchaser_id: buyer.id, link_id: @product.id)
            create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 100)
          end

          # A completed restart records the accepted terms and the pricing flag together.
          def owe_restart_charge_for(authenticated_offer_code_buyer)
            @subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer:)
            @subscription.update!(indian_card_mandate_restart_held: false, indian_card_mandate_restart_charge_pricing_pending: true)
          end

          it "queues a signed-out guest-price hold even though the account's existing-customer price is zero" do
            owe_restart_charge_for(nil)

            travel_to @six_months_after_purchase do
              described_class.new.perform(@batch_number)

              expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id, true)
            end
          end

          it "prices a hold from before the buyer was recorded for the subscription's user, whose existing-customer price is zero" do
            owe_restart_charge_for(buyer)
            @subscription.update!(indian_card_mandate_restart_buyer_id: nil, indian_card_mandate_restart_buyer_captured: false)

            travel_to @six_months_after_purchase do
              described_class.new.perform(@batch_number)

              expect(RecurringChargeWorker.jobs.size).to eq(0)
            end
          end

          it "does not queue an authenticated hold whose existing-customer price is zero" do
            owe_restart_charge_for(buyer)

            travel_to @six_months_after_purchase do
              described_class.new.perform(@batch_number)

              expect(RecurringChargeWorker.jobs.size).to eq(0)
            end
          end

          it "does not queue a membership with no restart pricing when the account's default price is zero" do
            travel_to @six_months_after_purchase do
              described_class.new.perform(@batch_number)

              expect(RecurringChargeWorker.jobs.size).to eq(0)
            end
          end

          context "when the buyer the restart was accepted for no longer exists" do
            let!(:other_subscription) do
              create(:subscription, link: @product, id: 1_010).tap do |subscription|
                create(:membership_purchase, subscription:, succeeded_at: @initial_purchase_time, price_cents: @product.default_tier.prices.first.price_cents)
              end
            end

            before do
              allow(ErrorNotifier).to receive(:notify)
              owe_restart_charge_for(buyer)
              @subscription.update!(indian_card_mandate_recovery_pending: true, indian_card_mandate_restart_buyer_id: buyer.id + 10_000)
              CompleteIndianCardMandateJob.jobs.clear
            end

            it "fails the membership without charging or redriving it, and still sweeps the rest of the batch" do
              travel_to @six_months_after_purchase do
                expect { described_class.new.perform(@batch_number) }.not_to raise_error

                expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[other_subscription.id, true]])
                expect(CompleteIndianCardMandateJob.jobs.size).to eq(0)
                @subscription.reload
                expect(@subscription).not_to be_alive
                expect(@subscription.failed_at).to be_present
                expect(@subscription).not_to be_indian_card_mandate_recovery_pending
                expect(@subscription).not_to be_indian_card_mandate_restart_charge_pricing_pending
                expect(ErrorNotifier).to have_received(:notify).with(
                  kind_of(String), subscription_id: @subscription.id, subscription: @subscription.external_id, buyer_id: buyer.id + 10_000
                )
              end
            end

            context "when the pricing changes between the buyer lookup and the terminal path's lock" do
              let(:other_buyer) { create(:user) }

              # The lookup finds the buyer missing; the change lands before the sweep takes the row lock.
              def change_pricing_after_lookup(&change)
                allow(Subscription::PricingBuyerMissing).to receive(:new).and_wrap_original do |original, *args|
                  original.call(*args).tap { change.call }
                end
              end

              def expect_membership_untouched
                @subscription.reload
                expect(@subscription).to be_alive
                expect(@subscription.failed_at).to be_nil
                expect(ErrorNotifier).not_to have_received(:notify)
                expect(CompleteIndianCardMandateJob.jobs.size).to eq(0)
              end

              it "keeps the membership and the pricing a newer submission recorded, and still sweeps the rest of the batch" do
                change_pricing_after_lookup do
                  Subscription.where(id: @subscription.id).update_all(
                    indian_card_mandate_restart_buyer_id: other_buyer.id, indian_card_mandate_restart_price_cents: 7_00
                  )
                end

                travel_to @six_months_after_purchase do
                  described_class.new.perform(@batch_number)

                  expect_membership_untouched
                  expect(@subscription).to be_indian_card_mandate_restart_charge_pricing_pending
                  expect(@subscription).to be_indian_card_mandate_recovery_pending
                  expect(@subscription.indian_card_mandate_restart_buyer_id).to eq(other_buyer.id)
                  expect(@subscription.indian_card_mandate_restart_price_cents).to eq(7_00)
                  expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[other_subscription.id, true]])
                end
              end

              it "keeps the membership when a charge settled the pricing in the meantime" do
                change_pricing_after_lookup do
                  Subscription.find(@subscription.id).tap do |settled|
                    settled.clear_indian_card_mandate_restart_charge_pricing
                    settled.update!(indian_card_mandate_recovery_pending: false)
                  end
                end

                travel_to @six_months_after_purchase do
                  described_class.new.perform(@batch_number)

                  expect_membership_untouched
                  expect(@subscription.indian_card_mandate_restart_price_cents).to be_nil
                end
              end

              it "keeps the membership and the pricing while a charge is in flight" do
                change_pricing_after_lookup do
                  create(:membership_purchase, subscription: @subscription, purchase_state: "in_progress", is_original_subscription_purchase: false)
                end

                travel_to @six_months_after_purchase do
                  described_class.new.perform(@batch_number)

                  expect_membership_untouched
                  expect(@subscription).to be_indian_card_mandate_restart_charge_pricing_pending
                end
              end
            end

            context "when failing the membership itself raises" do
              let(:error) { ActiveRecord::StatementInvalid.new("lock wait timeout") }
              let!(:notice_subscription) { create(:subscription, id: 1_020, deactivated_at: 1.day.ago, indian_card_mandate_restart_abandoned_notice_pending: true) }

              before do
                DeliverIndianCardMandateRestartNoticesJob.jobs.clear
                allow_any_instance_of(Subscription).to receive(:unsubscribe_and_fail!).and_raise(error)
              end

              it "reports it and still sweeps later subscriptions and redrives owed notices" do
                travel_to @six_months_after_purchase do
                  expect { described_class.new.perform(@batch_number) }.not_to raise_error

                  expect(ErrorNotifier).to have_received(:notify).with(error, subscription_id: @subscription.id)
                  expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[other_subscription.id, true]])
                  expect(CompleteIndianCardMandateJob.jobs.size).to eq(0)
                  expect(DeliverIndianCardMandateRestartNoticesJob.jobs.map { _1["args"] }).to eq([[notice_subscription.id]])
                end
              end

              it "rolls the terminal path back so the next sweep retries it" do
                travel_to @six_months_after_purchase do
                  described_class.new.perform(@batch_number)

                  @subscription.reload
                  expect(@subscription).to be_alive
                  expect(@subscription).to be_indian_card_mandate_restart_charge_pricing_pending
                  expect(@subscription.indian_card_mandate_restart_buyer_id).to eq(buyer.id + 10_000)
                end
              end
            end
          end
        end

        context "when pricing a restart raises an unrelated error" do
          let(:buyer) { create(:user) }
          let(:error) { ActiveRecord::StatementInvalid.new("connection lost") }
          let!(:other_subscription) do
            create(:subscription, link: @product, id: 1_010).tap do |subscription|
              create(:membership_purchase, subscription:, succeeded_at: @initial_purchase_time, price_cents: @product.default_tier.prices.first.price_cents)
            end
          end
          let!(:notice_subscription) { create(:subscription, id: 1_020, deactivated_at: 1.day.ago, indian_card_mandate_restart_abandoned_notice_pending: true) }

          before do
            allow(ErrorNotifier).to receive(:notify)
            DeliverIndianCardMandateRestartNoticesJob.jobs.clear
            @subscription.update!(user: buyer)
            @subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: buyer)
            @subscription.update!(indian_card_mandate_restart_held: false, indian_card_mandate_restart_charge_pricing_pending: true)
            allow(User).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
              raise error if kwargs[:id] == buyer.id

              original.call(*args, **kwargs)
            end
          end

          it "reports it, skips only that subscription, and still redrives owed notices" do
            travel_to @six_months_after_purchase do
              expect { described_class.new.perform(@batch_number) }.not_to raise_error

              expect(ErrorNotifier).to have_received(:notify).with(error, subscription_id: @subscription.id)
              expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[other_subscription.id, true]])
              expect(DeliverIndianCardMandateRestartNoticesJob.jobs.map { _1["args"] }).to eq([[notice_subscription.id]])
            end
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
