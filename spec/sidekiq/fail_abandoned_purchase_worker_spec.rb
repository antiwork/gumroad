# frozen_string_literal: true

require "spec_helper"

describe FailAbandonedPurchaseWorker, :vcr do
  include ManageSubscriptionHelpers

  describe "#perform" do
    let(:chargeable) { build(:chargeable, card: StripePaymentMethodHelper.success_with_sca) }

    context "when purchase has succeeded" do
      let!(:purchase) { create(:purchase) }

      before { travel ChargeProcessor::TIME_TO_COMPLETE_SCA }

      it "does nothing" do
        expect(ChargeProcessor).not_to receive(:cancel_charge_intent!)
        described_class.new.perform(purchase.id)
        expect(FailAbandonedPurchaseWorker.jobs.size).to eq(0)
      end
    end

    context "when purchase has failed" do
      let!(:purchase) { create(:failed_purchase) }

      before { travel ChargeProcessor::TIME_TO_COMPLETE_SCA }

      it "does nothing" do
        expect(ChargeProcessor).not_to receive(:cancel_charge_intent!)
        described_class.new.perform(purchase.id)
        expect(FailAbandonedPurchaseWorker.jobs.size).to eq(0)
      end
    end

    context "when purchase is in_progress" do
      describe "preorder purchase" do
        let(:product) { create(:product, is_in_preorder_state: true) }
        let!(:preorder_product) { create(:preorder_link, link: product) }

        let(:purchase) { create(:purchase_in_progress, link: product, chargeable:, is_preorder_authorization: true) }

        before do
          purchase.process!(off_session: false)
          travel ChargeProcessor::TIME_TO_COMPLETE_SCA
        end

        context "when purchase was abandoned and SCA never completed" do
          it "cancels the setup intent and marks purchase as failed" do
            expect(ChargeProcessor).to receive(:cancel_setup_intent!).and_call_original
            described_class.new.perform(purchase.id)
            expect(purchase.reload.purchase_state).to eq("preorder_authorization_failed")
          end
        end

        context "when setup intent has been canceled in parallel" do
          before do
            ChargeProcessor.cancel_setup_intent!(purchase.merchant_account, purchase.processor_setup_intent_id)
          end

          it "handles the error gracefully and does not change the purchase state" do
            described_class.new.perform(purchase.id)
            expect(purchase.reload.purchase_state).to eq("in_progress")
          end
        end

        context "when setup intent has succeeded in parallel" do
          before do
            # Unfortunately, Stripe does not provide a way to confirm a setup intent that's in `requires_action` state
            # without the Stripe SDK (i.e. the UI), so we simulate this.
            allow(ChargeProcessor).to receive(:cancel_setup_intent!).and_raise(ChargeProcessorError, "You cannot cancel this SetupIntent because it has a status of succeeded.")
            allow_any_instance_of(StripeSetupIntent).to receive(:succeeded?).and_return(true)
          end

          it "handles the error gracefully and does not change the purchase state" do
            described_class.new.perform(purchase.id)
            expect(purchase.reload.purchase_state).to eq("in_progress")
          end
        end

        context "when unexpected charge processor error occurs" do
          before do
            allow(ChargeProcessor).to receive(:cancel_setup_intent!).and_raise(ChargeProcessorError)
          end

          it "raises an error" do
            expect do
              described_class.new.perform(purchase.id)
            end.to raise_error(ChargeProcessorError)
          end
        end
      end

      describe "classic purchase" do
        let(:purchase) { create(:purchase_in_progress, chargeable:) }

        before do
          purchase.process!(off_session: false)
          travel ChargeProcessor::TIME_TO_COMPLETE_SCA
        end

        context "when purchase was abandoned and SCA never completed" do
          it "cancels the charge intent and marks purchase as failed" do
            expect(ChargeProcessor).to receive(:cancel_payment_intent!).and_call_original
            described_class.new.perform(purchase.id)
            expect(purchase.reload.purchase_state).to eq("failed")
          end
        end

        context "when payment intent has been canceled in parallel" do
          before do
            ChargeProcessor.cancel_payment_intent!(purchase.merchant_account, purchase.processor_payment_intent_id)
          end

          it "handles the error gracefully and does not change the purchase state" do
            described_class.new.perform(purchase.id)
            expect(purchase.reload.purchase_state).to eq("in_progress")
          end
        end

        context "when payment intent has succeeded in parallel" do
          before do
            # Unfortunately, Stripe does not provide a way to confirm a payment intent that's in `requires_action` state
            # without the Stripe SDK (i.e. the UI), so we simulate this.
            allow(ChargeProcessor).to receive(:cancel_payment_intent!).and_raise(ChargeProcessorError, "You cannot cancel this PaymentIntent because it has a status of succeeded.")
            allow_any_instance_of(StripeChargeIntent).to receive(:succeeded?).and_return(true)
            allow_any_instance_of(StripeChargeIntent).to receive(:load_charge)
          end

          it "handles the error gracefully and does not change the purchase state" do
            described_class.new.perform(purchase.id)
            expect(purchase.reload.purchase_state).to eq("in_progress")
          end
        end

        context "when unexpected charge processor error occurs" do
          before do
            allow(ChargeProcessor).to receive(:cancel_payment_intent!).and_raise(ChargeProcessorError)
          end

          it "raises an error" do
            expect do
              described_class.new.perform(purchase.id)
            end.to raise_error(ChargeProcessorError)
          end
        end
      end

      describe "abandoned client-confirm charge with method-forced presentment rows" do
        let(:seller) { create(:user) }
        let(:product) { create(:product, user: seller) }
        let(:purchase) { create(:purchase_in_progress, link: product, merchant_account: create(:merchant_account, user: seller)) }
        let(:charge) { create(:charge, seller:, stripe_payment_intent_id: "pi_abandoned_presentment", client_confirmed: true) }

        before do
          charge.purchases << purchase
          purchase.create_processor_payment_intent!(intent_id: "pi_abandoned_presentment")
          charge_presentment = create(:charge_presentment, charge:, presentment_currency: Currency::EUR,
                                                           stripe_fx_quote_id: nil, stripe_fx_quote_expires_at: nil, fx_rate: nil)
          create(:purchase_presentment, purchase:, charge_presentment:, presentment_currency: Currency::EUR)
          travel ChargeProcessor::TIME_TO_COMPLETE_SCA

          # The buyer bailed at the redirect: the intent is still awaiting confirmation, so the
          # worker cancels it. (Intent expiry has no separate path — a never-confirmed deferred
          # intent is cleaned up by exactly this abandonment cancel.)
          allow(Stripe::PaymentIntent).to receive(:retrieve).with("pi_abandoned_presentment")
            .and_return(Stripe::PaymentIntent.construct_from(id: "pi_abandoned_presentment", status: "requires_payment_method"))
          allow(ChargeProcessor).to receive(:cancel_payment_intent!)
        end

        it "cancels the intent, fails the purchase, and removes the orphaned presentment snapshot" do
          described_class.new.perform(purchase.id)

          expect(ChargeProcessor).to have_received(:cancel_payment_intent!)
          expect(purchase.reload).to be_failed
          expect(charge.reload.charge_presentment).to be_nil
          expect(purchase.purchase_presentment).to be_nil
          expect(ChargePresentment.count).to eq(0)
          expect(PurchasePresentment.count).to eq(0)
        end

        it "leaves nothing behind so a retried checkout's fresh prepare yields exactly one live presentment set" do
          described_class.new.perform(purchase.id)

          # The buyer retries: a new charge is prepared and persists its own snapshot.
          retry_charge = create(:charge, seller:, client_confirmed: true)
          retry_purchase = create(:purchase_in_progress, link: product)
          retry_charge.purchases << retry_purchase
          retry_presentment = create(:charge_presentment, charge: retry_charge, presentment_currency: Currency::EUR,
                                                          stripe_fx_quote_id: nil, stripe_fx_quote_expires_at: nil, fx_rate: nil)
          create(:purchase_presentment, purchase: retry_purchase, charge_presentment: retry_presentment, presentment_currency: Currency::EUR)

          expect(ChargePresentment.all).to eq([retry_presentment])
          expect(PurchasePresentment.count).to eq(1)
          expect(PurchasePresentment.sole.purchase).to eq(retry_purchase)
        end
      end

      describe "abandoned client-confirm charge without presentment rows (flag off / card checkout)" do
        let(:seller) { create(:user) }
        let(:purchase) { create(:purchase_in_progress, link: create(:product, user: seller), merchant_account: create(:merchant_account, user: seller)) }
        let(:charge) { create(:charge, seller:, stripe_payment_intent_id: "pi_abandoned_plain", client_confirmed: true) }

        before do
          charge.purchases << purchase
          purchase.create_processor_payment_intent!(intent_id: "pi_abandoned_plain")
          travel ChargeProcessor::TIME_TO_COMPLETE_SCA

          allow(Stripe::PaymentIntent).to receive(:retrieve).with("pi_abandoned_plain")
            .and_return(Stripe::PaymentIntent.construct_from(id: "pi_abandoned_plain", status: "requires_payment_method"))
          allow(ChargeProcessor).to receive(:cancel_payment_intent!)
        end

        it "cancels and fails without error when there is no snapshot to clean up" do
          expect { described_class.new.perform(purchase.id) }.not_to raise_error

          expect(purchase.reload).to be_failed
          expect(ChargePresentment.count).to eq(0)
        end
      end

      describe "client-confirm charge that succeeded but was never finalized" do
        let(:seller) { create(:user) }
        let(:product) { create(:product, user: seller) }
        let(:purchase) { create(:purchase_in_progress, link: product, merchant_account: create(:merchant_account, user: seller)) }
        let(:charge) { create(:charge, seller:, stripe_payment_intent_id: "pi_confirmed", client_confirmed: true) }
        let(:succeeded_intent) { instance_double(StripeChargeIntent, succeeded?: true, canceled?: false) }

        before do
          charge.purchases << purchase
          purchase.create_processor_payment_intent!(intent_id: "pi_confirmed")
          travel ChargeProcessor::TIME_TO_COMPLETE_SCA

          allow(Stripe::PaymentIntent).to receive(:retrieve).with("pi_confirmed")
            .and_return(Stripe::PaymentIntent.construct_from(id: "pi_confirmed", status: "succeeded"))
          allow_any_instance_of(Purchase).to receive(:cancel_charge_intent!)
            .and_raise(ChargeProcessorError, "You cannot cancel this PaymentIntent because it has a status of succeeded.")
          allow(ChargeProcessor).to receive(:get_charge_intent).and_return(succeeded_intent)
        end

        # Recovery of captured-but-abandoned client-confirm charges is deferred to the Phase 2 webhook;
        # the worker must not finalize here, and must not raise on a succeeded intent it can't cancel.
        it "leaves the purchase in_progress without finalizing" do
          expect(Purchase::FinalizeConfirmedChargeService).not_to receive(:new)

          expect { described_class.new.perform(purchase.id) }.not_to raise_error

          expect(purchase.reload).to be_in_progress
        end
      end

      context "membership upgrade purchase" do
        let(:user) { create(:user) }

        before do
          setup_subscription

          @indian_cc = create(:credit_card, user: user, chargeable: create(:chargeable, card: StripePaymentMethodHelper.success_indian_card_mandate))
          @subscription.credit_card = @indian_cc
          @subscription.save!

          params = {
            price_id: @quarterly_product_price.external_id,
            variants: [@new_tier.external_id],
            quantity: 1,
            use_existing_card: true,
            perceived_price_cents: @new_tier_quarterly_price.price_cents,
            perceived_upgrade_price_cents: @new_tier_quarterly_price.price_cents,
          }

          Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: "abc123",
            params:,
            logged_in_user: user,
            remote_ip: "11.22.33.44",
          ).perform

          @membership_upgrade_purchase = @subscription.reload.purchases.in_progress.last

          travel ChargeProcessor::TIME_TO_COMPLETE_SCA
        end

        context "when purchase was abandoned and SCA never completed" do
          it "cancels the charge intent, marks purchase as failed, and cancels membership upgrade" do
            expect(ChargeProcessor).to receive(:cancel_payment_intent!).and_call_original
            expect_any_instance_of(Purchase::MarkFailedService).to receive(:mark_items_failed).and_call_original
            expect(@membership_upgrade_purchase.reload.purchase_state).to eq("in_progress")
            expect(@subscription.reload.original_purchase.variant_attributes).to eq [@new_tier]

            described_class.new.perform(@membership_upgrade_purchase.id)

            expect(@membership_upgrade_purchase.reload.purchase_state).to eq("failed")
            expect(@subscription.reload.original_purchase.variant_attributes).to eq [@original_tier]
          end
        end
      end

      context "membership restart purchase" do
        let(:user) { create(:user) }

        before do
          setup_subscription

          @indian_cc = create(:credit_card, user: user, chargeable: create(:chargeable, card: StripePaymentMethodHelper.success_indian_card_mandate))
          @subscription.credit_card = @indian_cc
          @subscription.save!

          @subscription.update!(cancelled_at: @originally_subscribed_at + 4.months, cancelled_by_buyer: true)

          params = {
            price_id: @quarterly_product_price.external_id,
            variants: [@original_tier.external_id],
            quantity: 1,
            perceived_price_cents: @original_tier_quarterly_price.price_cents,
            perceived_upgrade_price_cents: @original_tier_quarterly_price.price_cents,
          }.merge(StripePaymentMethodHelper.success_indian_card_mandate.to_stripejs_params(prepare_future_payments: true))

          Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: "abc123",
            params:,
            logged_in_user: user,
            remote_ip: "11.22.33.44",
          ).perform

          @membership_restart_purchase = @subscription.reload.purchases.in_progress.last

          travel ChargeProcessor::TIME_TO_COMPLETE_SCA
        end

        context "when purchase was abandoned and SCA never completed" do
          it "cancels the charge intent, marks purchase as failed, and cancels membership upgrade" do
            expect(ChargeProcessor).to receive(:cancel_payment_intent!).and_call_original
            expect_any_instance_of(Purchase::MarkFailedService).to receive(:mark_items_failed).and_call_original
            expect(@membership_restart_purchase.reload.purchase_state).to eq("in_progress")
            expect(@subscription.reload.original_purchase.variant_attributes).to eq [@original_tier]
            expect(@subscription.is_resubscription_pending_confirmation?).to be true
            expect(@subscription.alive?).to be true

            described_class.new.perform(@membership_restart_purchase.id)

            expect(@membership_restart_purchase.reload.purchase_state).to eq("failed")
            expect(@subscription.reload.original_purchase.variant_attributes).to eq [@original_tier]
            expect(@subscription.is_resubscription_pending_confirmation?).to be false
            expect(@subscription.reload.alive?).to be false
          end
        end
      end

      context "when the job is called before time to complete SCA has expired" do
        let(:purchase) { create(:purchase_in_progress, chargeable:) }

        before do
          purchase.process!(off_session: false)
        end

        it "does not cancel payment intent and reschedules the job instead" do
          expect(ChargeProcessor).not_to receive(:cancel_charge_intent!)

          described_class.new.perform(purchase.id)

          expect(FailAbandonedPurchaseWorker).to have_enqueued_sidekiq_job(purchase.id)
        end
      end

      context "when purchase has no processor_payment_intent_id or processor_setup_intent_id" do
        let!(:purchase) { create(:purchase_in_progress) }

        before { travel ChargeProcessor::TIME_TO_COMPLETE_SCA }

        it "raises an error" do
          expect do
            expect(ChargeProcessor).not_to receive(:cancel_charge_intent!)

            described_class.new.perform(purchase.id)
          end.to raise_error(/Expected purchase #{purchase.id} to have either a processor_payment_intent_id or processor_setup_intent_id present/)
        end
      end
    end
  end
end
