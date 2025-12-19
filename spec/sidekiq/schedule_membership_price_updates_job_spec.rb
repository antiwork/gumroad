# frozen_string_literal: true

describe ScheduleMembershipPriceUpdatesJob do
  describe "perform" do
    context "for a non-tiered membership variant" do
      it "does nothing" do
        variant = create(:variant)
        purchase = create(:purchase, variant_attributes: [variant])
        create(:subscription, original_purchase: purchase)

        expect do
          described_class.new.perform(variant.id)
        end.not_to change { SubscriptionPlanChange.count }
      end
    end

    context "for a membership tier" do
      let(:yearly_price) { 10_99 }
      let(:product) do
        recurrence_price_values = [
          { monthly: { enabled: true, price: 3 }, yearly: { enabled: true, price: yearly_price / 100.0 } },
          { monthly: { enabled: true, price: 5 }, yearly: { enabled: true, price: 24.99 } }
        ]
        create(:membership_product_with_preset_tiered_pricing, recurrence_price_values:)
      end
      let(:effective_on) { 7.days.from_now.to_date }
      let(:enabled_tier) do
        tier = product.tiers.first
        tier.update!(apply_price_changes_to_existing_memberships: true, subscription_price_change_effective_date: effective_on)
        tier
      end
      let(:disabled_tier) { product.tiers.last }
      let(:new_price) { enabled_tier.prices.find_by(recurrence: "monthly").price_cents }
      let(:original_price) { new_price - 1_00 }
      let(:enabled_subscription) { create(:membership_purchase, price_cents: original_price, link: product, variant_attributes: [enabled_tier]).subscription }
      let(:disabled_subscription) { create(:membership_purchase, link: product, variant_attributes: [disabled_tier]).subscription }

      context "for a tier with apply_price_changes_to_existing_memberships disabled" do
        it "does nothing" do
          described_class.new.perform(disabled_tier.id)

          expect(SubscriptionPlanChange.count).to eq(0)
        end

        context "that has a pending plan change to an enabled tier" do
          it "records a plan change" do
            subscription = create(:membership_purchase, link: product, variant_attributes: [disabled_tier]).subscription
            create(:subscription_plan_change, subscription:, tier: enabled_tier)

            described_class.new.perform(enabled_tier.id)

            expect(subscription.subscription_plan_changes.for_product_price_change.alive.count).to eq(1)
          end
        end
      end

      context "for a tier with apply_price_changes_to_existing_memberships enabled" do
        it "records a plan change for each live or pending cancellation subscription on the next charge after the effective date" do
          effective_on_next_billing_period = create(:membership_purchase, link: product, variant_attributes: [enabled_tier], succeeded_at: 2.weeks.ago).subscription
          effective_in_two_billing_periods = create(:membership_purchase, link: product, variant_attributes: [enabled_tier], succeeded_at: 25.days.ago).subscription
          pending_cancellation = create(:membership_purchase, link: product, variant_attributes: [enabled_tier], succeeded_at: 2.weeks.ago).tap do
            _1.subscription.update!(cancelled_at: 1.day.ago)
          end.subscription
          create(:membership_purchase, link: product, variant_attributes: [disabled_tier])
          create(:membership_purchase, variant_attributes: [disabled_tier])
          create(:membership_purchase)

          expect do
            described_class.new.perform(enabled_tier.id)
          end.to change { SubscriptionPlanChange.count }.by(3)
             .and change { Purchase.count }.by(0) # test that `Subscription#update_current_plan!` changes are rolled back

          expect(effective_on_next_billing_period.subscription_plan_changes.for_product_price_change.alive.count).to eq(1)
          expect(effective_on_next_billing_period.subscription_plan_changes.sole.effective_on).to eq(effective_on_next_billing_period.end_time_of_subscription.to_date)

          expect(pending_cancellation.subscription_plan_changes.for_product_price_change.alive.count).to eq(1)
          expect(pending_cancellation.subscription_plan_changes.sole.effective_on).to eq(pending_cancellation.end_time_of_subscription.to_date)

          expect(effective_in_two_billing_periods.subscription_plan_changes.for_product_price_change.alive.count).to eq(1)
          expect(effective_in_two_billing_periods.subscription_plan_changes.sole.effective_on).to eq(
            (effective_in_two_billing_periods.end_time_of_subscription + effective_in_two_billing_periods.period).to_date
          )
        end

        context "when the subscription has an offer code" do
          it "applies the offer code when calculating the new price" do
            offer_code = create(:offer_code, user: product.user, amount_cents: 1_50)
            enabled_subscription.original_purchase.update!(offer_code:)

            expect do
              described_class.new.perform(enabled_tier.id)
            end.to change { enabled_subscription.subscription_plan_changes.count }.by(1)
               .and change { Purchase.count }.by(0) # test that `Subscription#update_current_plan!` changes are rolled back

            latest_plan_change = enabled_subscription.subscription_plan_changes.for_product_price_change.last
            expect(latest_plan_change.tier).to eq enabled_tier
            expect(latest_plan_change.recurrence).to eq enabled_subscription.recurrence
            expect(latest_plan_change.perceived_price_cents).to eq new_price - 1_50
          end
        end

        context "when the subscription has a pending plan change" do
          context "that will switch away from the given tier" do
            it "does nothing" do
              create(:subscription_plan_change, subscription: enabled_subscription, tier: disabled_tier)
              expect do
                described_class.new.perform(enabled_tier.id)
              end.not_to change { enabled_subscription.subscription_plan_changes.count }
            end
          end

          context "that will switch to the given tier" do
            it "records a subscription plan change if the price is different from the agreed on price" do
              create(:subscription_plan_change, subscription: disabled_subscription, tier: enabled_tier, perceived_price_cents: new_price - 1)
              expect do
                described_class.new.perform(enabled_tier.id)
              end.to change { disabled_subscription.purchases.count }.by(0) # test that `Subscription#update_current_plan!` changes are rolled back
                 .and change { disabled_subscription.subscription_plan_changes.count }.by(1)

              latest_plan_change = disabled_subscription.subscription_plan_changes.for_product_price_change.last
              expect(latest_plan_change.tier).to eq enabled_tier
              expect(latest_plan_change.recurrence).to eq enabled_subscription.recurrence
              expect(latest_plan_change.perceived_price_cents).to eq new_price
              expect(latest_plan_change.effective_on).to eq(disabled_subscription.end_time_of_subscription.to_date)
            end

            it "does nothing but notify Bugsnag if the price is the same as the agreed on price" do
              expect(Bugsnag).to receive(:notify).with("Not adding a plan change for membership price change - subscription_id: #{disabled_subscription.id} - reason: price has not changed")
              create(:subscription_plan_change, subscription: disabled_subscription, tier: enabled_tier, perceived_price_cents: new_price)
              expect do
                described_class.new.perform(enabled_tier.id)
              end.not_to change { disabled_subscription.subscription_plan_changes.count }
            end
          end

          context "that switches billing periods" do
            it "records a subscription plan change if the new price is different from the agreed on price" do
              create(:subscription_plan_change, subscription: enabled_subscription, tier: enabled_tier, recurrence: "yearly", perceived_price_cents: yearly_price - 1)
              expect do
                described_class.new.perform(enabled_tier.id)
              end.to change { enabled_subscription.purchases.count }.by(0)
                 .and change { enabled_subscription.subscription_plan_changes.count }.by(1)

              latest_plan_change = enabled_subscription.subscription_plan_changes.for_product_price_change.last
              expect(latest_plan_change.tier).to eq enabled_tier
              expect(latest_plan_change.recurrence).to eq "yearly"
              expect(latest_plan_change.perceived_price_cents).to eq yearly_price
            end

            it "does nothing but notify Bugsnag if the new price is the same as the agreed on price" do
              expect(Bugsnag).to receive(:notify).with("Not adding a plan change for membership price change - subscription_id: #{enabled_subscription.id} - reason: price has not changed")
              create(:subscription_plan_change, subscription: enabled_subscription, tier: enabled_tier, recurrence: "yearly", perceived_price_cents: yearly_price)
              expect do
                described_class.new.perform(enabled_tier.id)
              end.not_to change { enabled_subscription.subscription_plan_changes.count }
            end
          end

          it "deletes existing plan changes for product price changes, but not user-initiated plan changes" do
            by_user = create(:subscription_plan_change, subscription: disabled_subscription, tier: enabled_tier, perceived_price_cents: new_price - 1)
            for_price_change = create(:subscription_plan_change, subscription: disabled_subscription, for_product_price_change: true)

            described_class.new.perform(enabled_tier.id)

            expect(by_user.reload).not_to be_deleted
            expect(for_price_change.reload).to be_deleted
          end

          context "but updating the subscription raises an error" do
            it "rolls back the transaction and does not retry" do
              allow_any_instance_of(Subscription).to receive(:update_current_plan!).and_raise(Subscription::UpdateFailed)
              create(:subscription_plan_change, subscription: disabled_subscription, tier: enabled_tier, perceived_price_cents: new_price - 1)
              expect do
                described_class.new.perform(enabled_tier.id)
              end.not_to change { disabled_subscription.purchases.count }

              expect(described_class.jobs.size).to eq(0)
            end
          end
        end

        context "for a fixed length subscription that has completed its charges" do
          it "does nothing" do
            sub = create(:membership_purchase, link: product, variant_attributes: [enabled_tier]).subscription
            sub.update!(charge_occurrence_count: 1)

            expect do
              described_class.new.perform(enabled_tier.id)
            end.not_to change { sub.reload.subscription_plan_changes.count }
          end
        end

        context "for a subscription that is inactive" do
          it "does nothing" do
            enabled_subscription.deactivate!
            expect do
              described_class.new.perform(enabled_tier.id)
            end.not_to change { enabled_subscription.subscription_plan_changes.count }
          end
        end

        context "when the price has not changed" do
          it "does nothing but notify Bugsnag" do
            expect(Bugsnag).to receive(:notify).with("Not adding a plan change for membership price change - subscription_id: #{enabled_subscription.id} - reason: price has not changed")
            enabled_subscription.original_purchase.update!(displayed_price_cents: new_price)

            expect do
              described_class.new.perform(enabled_tier.id)
            end.not_to change { enabled_subscription.subscription_plan_changes.count }
          end
        end

        context "when the price for a recurrence is deleted" do
          it "does nothing but notify Bugsnag" do
            enabled_tier.prices.alive.find_by(recurrence: "monthly").mark_deleted!

            expect(Bugsnag).to receive(:notify).with(/subscription_id: #{enabled_subscription.id} - reason: zero or negative price/)

            expect do
              described_class.new.perform(enabled_tier.id)
            end.not_to change { enabled_subscription.reload.subscription_plan_changes.count }

            zero_price_plan_changes = enabled_subscription.subscription_plan_changes
                                                         .for_product_price_change
                                                         .where(perceived_price_cents: 0)
            expect(zero_price_plan_changes.count).to eq(0)
            expect(enabled_subscription.current_subscription_price_cents).to eq(original_price)
            expect(enabled_subscription.latest_applicable_plan_change).to be_nil
            expect(enabled_subscription.build_purchase.perceived_price_cents).to eq(original_price)
          end
        end
      end
    end
  end
end
