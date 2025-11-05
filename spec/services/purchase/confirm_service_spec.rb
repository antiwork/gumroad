# frozen_string_literal: false

describe Purchase::ConfirmService, :vcr do
  include ManageSubscriptionHelpers

  let(:user) { create(:user) }
  let(:chargeable) { build(:chargeable, card: StripePaymentMethodHelper.success_sca_not_required) }

  context "when purchase has been marked as failed" do
    # Sometimes we mark a purchase failed before the confirmation request comes from the UI,
    # if time to complete SCA expired or a parallel purchase has been made.
    let(:purchase) { create(:failed_purchase, chargeable:) }

    it "returns an error message" do
      expect(ChargeProcessor).not_to receive(:confirm_payment_intent!)
      error_message = Purchase::ConfirmService.new(purchase:, params: {}).perform
      expect(error_message).to eq("There is a temporary problem, please try again (your card was not charged).")
    end
  end

  context "when SCA fails" do
    context "for a classic product" do
      let(:purchase) { create(:purchase_in_progress, chargeable:) }

      before do
        purchase.process!
        params = {
          stripe_error: {
            code: "invalid_request_error",
            message: "We are unable to authenticate your payment method."
          }
        }
        @error_message = Purchase::ConfirmService.new(purchase:, params:).perform
      end

      it "marks purchase as failed and returns an error message" do
        expect(@error_message).to eq("We are unable to authenticate your payment method.")
        expect(purchase.reload.purchase_state).to eq("failed")
      end

      it "does not enqueue activate integrations worker" do
        expect(@error_message).to eq("We are unable to authenticate your payment method.")
        expect(ActivateIntegrationsWorker.jobs.size).to eq(0)
      end
    end

    context "for a pre-order product" do
      let(:product) { create(:product_with_files, is_in_preorder_state: true) }
      let(:preorder_product) { create(:preorder_link, link: product, release_at: 25.hours.from_now) }
      let(:authorization_purchase) { create(:purchase_in_progress, link: product, chargeable:, is_preorder_authorization: true) }

      before do
        preorder_product.build_preorder(authorization_purchase)
      end

      it "marks pre-order as authorization_failed and returns an error message" do
        params = {
          stripe_error: {
            code: "invalid_request_error",
            message: "We are unable to authenticate your payment method."
          }
        }

        error_message = Purchase::ConfirmService.new(purchase: authorization_purchase, params:).perform

        expect(error_message).to eq("We are unable to authenticate your payment method.")
        expect(authorization_purchase.reload.purchase_state).to eq("preorder_authorization_failed")
        expect(authorization_purchase.preorder.state).to eq("authorization_failed")
      end
    end

    context "for a membership upgrade purchase" do
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
      end

      it "reverts the subscription to old tier and returns an error message" do
        expect(@membership_upgrade_purchase.purchase_state).to eq("in_progress")
        expect(@subscription.original_purchase.variant_attributes).to eq [@new_tier]
        expect_any_instance_of(Purchase::BaseService).to receive(:mark_items_failed).and_call_original

        params = {
          stripe_error: {
            code: "invalid_request_error",
            message: "We are unable to authenticate your payment method."
          }
        }

        error_message = Purchase::ConfirmService.new(purchase: @membership_upgrade_purchase, params:).perform

        expect(error_message).to eq("We are unable to authenticate your payment method.")
        expect(@membership_upgrade_purchase.reload.purchase_state).to eq("failed")
        expect(@subscription.reload.original_purchase.variant_attributes).to eq [@original_tier]
      end
    end

    context "for a membership restart purchase" do
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
      end

      it "marks the purchase as failed and unsubscribes the membership" do
        expect(@membership_restart_purchase.purchase_state).to eq("in_progress")
        expect(@subscription.reload.is_resubscription_pending_confirmation?).to be true
        expect(@subscription.alive?).to be(true)
        expect(@subscription).not_to receive(:send_restart_notifications!)
        expect(@subscription).to receive(:unsubscribe_and_fail!).and_call_original
        expect_any_instance_of(Purchase::BaseService).to receive(:mark_items_failed).and_call_original

        params = {
          stripe_error: {
            code: "invalid_request_error",
            message: "We are unable to authenticate your payment method."
          }
        }

        error_message = Purchase::ConfirmService.new(purchase: @membership_restart_purchase, params:).perform

        expect(error_message).to eq("We are unable to authenticate your payment method.")
        expect(@membership_restart_purchase.reload.failed?).to be true
        expect(@subscription.reload.is_resubscription_pending_confirmation?).to be false
        expect(@subscription.alive?).to be(false)
      end
    end
  end

  context "when SCA succeeds" do
    context "for a classic product" do
      let(:purchase) { create(:purchase_in_progress, chargeable:) }

      before do
        purchase.process!
      end

      it "marks purchase as successful" do
        allow_any_instance_of(Stripe::PaymentIntent).to receive(:confirm)

        error_message = Purchase::ConfirmService.new(purchase:, params: {}).perform

        expect(error_message).to be_nil
        expect(purchase.reload.purchase_state).to eq("successful")
      end

      it "does not return an error if purchase is already successful" do
        purchase.update_balance_and_mark_successful!
        expect(purchase.reload.purchase_state).to eq("successful")

        allow_any_instance_of(Stripe::PaymentIntent).to receive(:confirm)

        error_message = Purchase::ConfirmService.new(purchase:, params: {}).perform

        expect(error_message).to be_nil
        expect(purchase.reload.purchase_state).to eq("successful")
      end

      it "enqueues activate integrations worker" do
        allow_any_instance_of(Stripe::PaymentIntent).to receive(:confirm)

        error_message = Purchase::ConfirmService.new(purchase:, params: {}).perform

        expect(error_message).to be_nil
        expect(purchase.reload.purchase_state).to eq("successful")
        expect(ActivateIntegrationsWorker).to have_enqueued_sidekiq_job(purchase.id)
      end

      context "when charge processor is unavailable" do
        before do
          allow(ChargeProcessor).to receive(:confirm_payment_intent!).and_raise(ChargeProcessorUnavailableError)
        end

        it "marks purchase as failed and returns an error message" do
          error_message = Purchase::ConfirmService.new(purchase:, params: {}).perform

          expect(error_message).to eq("There is a temporary problem, please try again (your card was not charged).")
          expect(purchase.reload.purchase_state).to eq("failed")
        end
      end
    end

    context "for a pre-order product" do
      let(:product) { create(:product_with_files, is_in_preorder_state: true) }
      let(:preorder_product) { create(:preorder_link, link: product, release_at: 25.hours.from_now) }
      let(:authorization_purchase) { create(:purchase_in_progress, link: product, chargeable:, is_preorder_authorization: true) }

      before do
        preorder_product.build_preorder(authorization_purchase)
      end

      it "marks pre-order successful" do
        error_message = Purchase::ConfirmService.new(purchase: authorization_purchase, params: {}).perform

        expect(error_message).to be_nil
        expect(authorization_purchase.reload.purchase_state).to eq("preorder_authorization_successful")
        expect(authorization_purchase.preorder.state).to eq("authorization_successful")
      end
    end

    context "for a membership upgrade purchase" do
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
      end

      it "marks the purchase as successful and updates integrations" do
        expect(@membership_upgrade_purchase.purchase_state).to eq("in_progress")
        expect(@subscription.original_purchase.variant_attributes).to eq [@new_tier]
        allow_any_instance_of(Purchase).to receive(:confirm_charge_intent!).and_return true
        expect(@subscription).not_to receive(:send_restart_notifications!)
        expect(@subscription).to receive(:handle_purchase_success)

        error_message = Purchase::ConfirmService.new(purchase: @membership_upgrade_purchase, params: {}).perform

        expect(error_message).to be nil
        expect(@subscription.reload.original_purchase.variant_attributes).to eq [@new_tier]
      end
    end

    context "for a membership restart purchase" do
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
      end

      it "marks the purchase as successful and sends membership restart notifications" do
        expect(@membership_restart_purchase.purchase_state).to eq("in_progress")
        expect(@subscription.reload.is_resubscription_pending_confirmation?).to be true
        expect(@subscription.alive?).to be(true)
        allow_any_instance_of(Purchase).to receive(:confirm_charge_intent!).and_return true
        expect(@subscription).to receive(:send_restart_notifications!)
        expect(@subscription).to receive(:handle_purchase_success)

        error_message = Purchase::ConfirmService.new(purchase: @membership_restart_purchase, params: {}).perform

        expect(error_message).to be nil
        expect(@subscription.is_resubscription_pending_confirmation?).to be false
        expect(@subscription.alive?).to be(true)
      end
    end
  end
end
