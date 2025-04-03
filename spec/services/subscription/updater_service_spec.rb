# frozen_string_literal: true

require "spec_helper"

describe Subscription::UpdaterService, :vcr do
  include ManageSubscriptionHelpers
  include CurrencyHelper

  describe "#perform" do
    context "tiered membership subscription" do
      let(:gift) { nil }
      before :each do
        setup_subscription(free_trial:, gift:)

        @remote_ip = "11.22.33.44"
        @gumroad_guid = "abc123"
        travel_to(@originally_subscribed_at + 1.month)
      end

      let(:free_trial) { false }
      let(:same_plan_params) do
        {
          price_id: @quarterly_product_price.external_id,
          variants: [@original_tier.external_id],
          quantity: 1,
          use_existing_card: true,
          perceived_price_cents: @original_tier_quarterly_price.price_cents,
          perceived_upgrade_price_cents: 0,
        }
      end

      let(:update_card_params) do
        params = same_plan_params.except(:use_existing_card)
        params.merge(CardParamsSpecHelper.success.to_stripejs_params)
      end

      let(:email) { generate(:email) }
      let(:update_contact_info_params) do
        same_plan_params.merge({
                                 contact_info: {
                                   full_name: "Jane Gumroad",
                                   email:,
                                   street_address: "100 Main St",
                                   city: "San Francisco",
                                   state: "CA",
                                   zip_code: "12345",
                                   country: "US",
                                 },
                               })
      end

      let(:upgrade_tier_params) do
        {
          price_id: @quarterly_product_price.external_id,
          variants: [@new_tier.external_id],
          quantity: 1,
          use_existing_card: true,
          perceived_price_cents: @new_tier_quarterly_price.price_cents,
          perceived_upgrade_price_cents: @new_tier_quarterly_upgrade_cost_after_one_month,
        }
      end

      let(:upgrade_recurrence_params) do
        {
          price_id: @yearly_product_price.external_id,
          variants: [@original_tier.external_id],
          quantity: 1,
          use_existing_card: true,
          perceived_price_cents: @original_tier_yearly_price.price_cents,
          perceived_upgrade_price_cents: @original_tier_yearly_upgrade_cost_after_one_month,
        }
      end

      let(:downgrade_tier_params) do
        {
          price_id: @quarterly_product_price.external_id,
          variants: [@lower_tier.external_id],
          quantity: 1,
          use_existing_card: true,
          perceived_price_cents: @lower_tier_quarterly_price.price_cents,
          perceived_upgrade_price_cents: 0,
        }
      end

      let(:downgrade_recurrence_params) do
        {
          price_id: @monthly_product_price.external_id,
          variants: [@original_tier.external_id],
          quantity: 1,
          use_existing_card: true,
          perceived_price_cents: 3_00,
          perceived_upgrade_price_cents: 0,
        }
      end

      let(:every_two_years_params) do
        {
          price_id: @every_two_years_product_price.external_id,
          variants: [@original_tier.external_id],
          quantity: 1,
          use_existing_card: true,
          perceived_price_cents: @original_tier_every_two_years_price.price_cents,
          perceived_upgrade_price_cents: @original_tier_every_two_years_upgrade_cost_after_one_month,
        }
      end

      describe "updating the credit card" do
        it "updates the subscription but not the user's card" do
          service = Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: update_card_params,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          )

          expect do
            service.perform
          end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :subscription_giftee_added_card)

          @subscription.reload
          @user.reload
          expect(@subscription.credit_card).to be
          expect(@subscription.credit_card).not_to eq @credit_card
          expect(@user.credit_card).to be
          expect(@user.credit_card).to eq @credit_card
        end

        it "does not switch the subscription to new flat fee" do
          expect(@subscription.flat_fee_applicable?).to be false

          result = Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: update_card_params,
            logged_in_user: @user,
            remote_ip: @remote_ip,
            ).perform

          expect(result[:success]).to eq true
          expect(@subscription.reload.flat_fee_applicable?).to be false
        end

        context "when the new card requires e-mandate" do
          it "updates the subscription but not the user's card" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: update_card_params.merge(StripePaymentMethodHelper.success_indian_card_mandate.to_stripejs_params),
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(@subscription.reload.credit_card).not_to eq @credit_card
            expect(@user.reload.credit_card).to eq @credit_card
          end
        end
      end

      describe "restarting a membership" do
        before :each do
          travel_to(@originally_subscribed_at + 4.months)

          @subscription.update!(cancelled_at: 1.day.ago, cancelled_by_buyer: true)
        end

        let(:existing_card_params) do
          {
            price_id: @quarterly_product_price.external_id,
            variants: [@original_tier.external_id],
            quantity: 1,
            use_existing_card: true,
            perceived_price_cents: @original_tier_quarterly_price.price_cents,
            perceived_upgrade_price_cents: @original_tier_quarterly_price.price_cents,
          }
        end

        context "using the existing card" do
          it "reactivates the subscription" do
            expect(@subscription).to receive(:send_restart_notifications!)
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: existing_card_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true

            @subscription.reload
            expect(@subscription).to be_alive
            expect(@subscription.cancelled_at).to be_nil
          end

          it "charges the existing card" do
            expect(@subscription).to receive(:send_restart_notifications!)
            old_card = @original_purchase.credit_card

            expect do
              Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: existing_card_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform
            end.to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }.by(1)

            last_purchase = @subscription.last_successful_charge

            expect(last_purchase.id).not_to eq @original_purchase.id
            expect(last_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents
            expect(last_purchase.credit_card).to eq old_card
            expect(last_purchase.is_upgrade_purchase).to eq false
          end

          it "does not update the user's credit card" do
            expect(@subscription).to receive(:send_restart_notifications!)

            expect do
              expect do
                Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params: existing_card_params,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform
              end.not_to change { @subscription.reload.credit_card }
            end.not_to change { @user.reload.credit_card }
          end

          it "raises error if both subscription and user payment methods are not supported by the creator" do
            paypal_credit_card = create(:credit_card, chargeable: build(:native_paypal_chargeable), user: @user)
            @subscription.update!(credit_card: paypal_credit_card)
            @user.update!(credit_card: paypal_credit_card)

            expect(@subscription).not_to receive(:send_restart_notifications!)
            expect(@subscription).not_to receive(:resubscribe!)

            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: existing_card_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq false
            expect(result[:error_message]).to eq "There is a problem with creator's paypal account, please try again later (your card was not charged)."
            expect(@subscription.reload).not_to be_alive
          end

          it "does not send email when charge user fails" do
            travel_to(@originally_subscribed_at + 3.months)
            @subscription.update!(cancelled_at: 1.day.ago, cancelled_by_buyer: true)

            expect(@subscription).not_to receive(:send_restart_notifications!)

            service = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: existing_card_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            )

            mock_error_msg = "error message"
            expect(service).to receive(:charge_user!).and_raise(Subscription::UpdateFailed, mock_error_msg)

            result = service.perform

            expect(result[:success]).to eq false
            expect(result[:error_message]).to eq mock_error_msg
            expect(@subscription.reload).not_to be_alive
          end

          it "does not raise error if the user payment method is not supported by the creator but subscription one is" do
            expect(@subscription).to receive(:send_restart_notifications!)
            paypal_credit_card = create(:credit_card, chargeable: build(:native_paypal_chargeable), user: @user)
            @user.update!(credit_card: paypal_credit_card)

            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: existing_card_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true
            expect(@subscription.reload).to be_alive
          end

          it "switches the subscription to new flat fee" do
            expect(@subscription.flat_fee_applicable?).to be false

            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: existing_card_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
              ).perform

            expect(result[:success]).to eq true
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end
        end

        context "using a new card" do
          let(:params) do
            {
              price_id: @quarterly_product_price.external_id,
              variants: [@original_tier.external_id],
              quantity: 1,
              perceived_price_cents: @original_tier_quarterly_price.price_cents,
              perceived_upgrade_price_cents: @original_tier_quarterly_price.price_cents,
            }.merge(StripePaymentMethodHelper.success.to_stripejs_params(prepare_future_payments: true))
          end

          it "reactivates the subscription" do
            expect(@subscription).to receive(:send_restart_notifications!)
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true

            @subscription.reload
            expect(@subscription).to be_alive
            expect(@subscription.cancelled_at).to be_nil
          end

          it "charges the new card" do
            expect(@subscription).to receive(:send_restart_notifications!)
            old_card = @original_purchase.credit_card

            expect do
              Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform
            end.to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }.by(1)

            last_purchase = @subscription.last_successful_charge

            expect(last_purchase.id).not_to eq @original_purchase.id
            expect(last_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents
            expect(last_purchase.credit_card).not_to eq old_card
            expect(last_purchase.is_upgrade_purchase).to eq false
          end

          it "updates the subscription's card" do
            expect(@subscription).to receive(:send_restart_notifications!)
            old_subscription_card = @subscription.credit_card
            old_user_card = @user.credit_card

            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(@subscription.reload.credit_card).to be
            expect(@subscription.credit_card).not_to eq old_subscription_card
            expect(@user.reload.credit_card).to be
            expect(@user.credit_card).to eq old_user_card
          end

          it "switches the subscription to new flat fee" do
            expect(@subscription.flat_fee_applicable?).to be false

            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
              ).perform

            expect(result[:success]).to eq true
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end

          context "when the new card requires e-mandate" do
            let(:params) do
              {
                price_id: @quarterly_product_price.external_id,
                variants: [@original_tier.external_id],
                quantity: 1,
                perceived_price_cents: @original_tier_quarterly_price.price_cents,
                perceived_upgrade_price_cents: @original_tier_quarterly_price.price_cents,
              }.merge(StripePaymentMethodHelper.success_indian_card_mandate.to_stripejs_params(prepare_future_payments: true))
            end

            it "charges the new card and returns proper SCA response" do
              expect(@subscription).not_to receive(:send_restart_notifications!)
              old_card = @original_purchase.credit_card
              PostToPingEndpointsWorker.jobs.clear

              response = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(@subscription.reload.purchases.in_progress.not_is_original_subscription_purchase.count).to eq(1)
              expect(@subscription.alive?).to be true
              expect(@subscription.is_resubscription_pending_confirmation?).to be true
              expect(@subscription.credit_card.last_four_digits).to eq("0123")

              last_purchase = @subscription.purchases.last
              expect(last_purchase.id).not_to eq @original_purchase.id
              expect(last_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents
              expect(last_purchase.credit_card).not_to eq old_card
              expect(last_purchase.in_progress?).to be true
              expect(last_purchase.is_upgrade_purchase).to eq false

              expect(response[:success]).to be true
              expect(response[:requires_card_action]).to be true
              expect(response[:client_secret]).to be_present
              expect(response[:purchase][:id]).to eq(last_purchase.external_id)
              expect(PostToPingEndpointsWorker.jobs.size).to eq(0)
            end
          end
        end

        context "when the price has changed" do
          it "charges the pre-existing price" do
            old_price_cents = @original_tier_quarterly_price.price_cents
            @original_tier_quarterly_price.update!(price_cents: old_price_cents + 500)

            params = {
              price_id: @quarterly_product_price.external_id,
              variants: [@original_tier.external_id],
              quantity: 1,
              use_existing_card: true,
              perceived_price_cents: old_price_cents,
              perceived_upgrade_price_cents: old_price_cents,
            }

            expect(@subscription.flat_fee_applicable?).to be false

            expect do
              Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform
            end.to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }.by(1)

            last_purchase = @subscription.last_successful_charge

            expect(last_purchase.id).not_to eq @original_purchase.id
            expect(last_purchase.displayed_price_cents).to eq old_price_cents
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end
        end

        context "changing plans" do
          it "allows downgrading recurrence immediately" do
            expect do
              params = downgrade_recurrence_params.merge(perceived_upgrade_price_cents: downgrade_recurrence_params[:perceived_price_cents])
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true
              expect(result[:success_message]).to eq "Membership restarted"
              expect(@subscription.reload.flat_fee_applicable?).to be true

              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).not_to eq @original_purchase.id
              expect(updated_purchase.price_cents).to eq @original_tier_monthly_price.price_cents
            end.not_to change { SubscriptionPlanChange.count }
          end

          it "allows upgrading recurrence immediately" do
            params = upgrade_recurrence_params.merge(perceived_upgrade_price_cents: upgrade_recurrence_params[:perceived_price_cents])
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true
            expect(result[:success_message]).to eq "Membership restarted"
            expect(@subscription.reload.flat_fee_applicable?).to be true

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.id).not_to eq @original_purchase.id
            expect(updated_purchase.price_cents).to eq @original_tier_yearly_price.price_cents
          end

          it "allows downgrading tier immediately" do
            expect do
              params = downgrade_tier_params.merge(perceived_upgrade_price_cents: downgrade_tier_params[:perceived_price_cents])
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true
              expect(result[:success_message]).to eq "Membership restarted"
              expect(@subscription.reload.flat_fee_applicable?).to be true

              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).not_to eq @original_purchase.id
              expect(updated_purchase.variant_attributes).to eq [@lower_tier]
              expect(updated_purchase.price_cents).to eq @lower_tier_quarterly_price.price_cents
            end.not_to change { SubscriptionPlanChange.count }
          end

          it "allows upgrading tier immediately" do
            params = upgrade_tier_params.merge(perceived_upgrade_price_cents: upgrade_tier_params[:perceived_price_cents])
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true
            expect(result[:success_message]).to eq "Membership restarted"
            expect(@subscription.reload.flat_fee_applicable?).to be true

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.id).not_to eq @original_purchase.id
            expect(updated_purchase.variant_attributes).to eq [@new_tier]
            expect(updated_purchase.price_cents).to eq @new_tier_quarterly_price.price_cents
          end

          it "allows upgrading tier immediately when card on record requires an e-mandate" do
            indian_cc = create(:credit_card, user: @user, chargeable: create(:chargeable, card: StripePaymentMethodHelper.success_indian_card_mandate))
            @subscription.credit_card = indian_cc
            @subscription.save!

            params = upgrade_tier_params.merge(perceived_upgrade_price_cents: upgrade_tier_params[:perceived_price_cents])
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true
            expect(result[:requires_card_action]).to be true
            expect(@subscription.reload.flat_fee_applicable?).to be true

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.id).not_to eq @original_purchase.id
            expect(updated_purchase.variant_attributes).to eq [@new_tier]
            expect(updated_purchase.price_cents).to eq @new_tier_quarterly_price.price_cents
          end
        end

        describe "changing quantity" do
          before do
            setup_subscription(quantity: 2)
          end

          context "when increasing quantity" do
            it "immediately updates the purchase and charges the user" do
              expect(@subscription.flat_fee_applicable?).to be false
              travel_to(@originally_subscribed_at + 1.day)
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: same_plan_params.merge({ quantity: 3, perceived_price_cents: 1797, perceived_upgrade_price_cents: 625 }),
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform
              expect(result[:success]).to eq(true)

              last_purchase = @subscription.last_successful_charge
              expect(last_purchase.id).not_to eq @original_purchase.id
              expect(last_purchase.displayed_price_cents).to eq 625
              original_purchase = @subscription.original_purchase
              expect(original_purchase.displayed_price_cents).to eq 1797
              expect(original_purchase.quantity).to eq 3
              expect(@subscription.reload.flat_fee_applicable?).to be true
            end
          end

          context "when decreasing quantity" do
            it "creates a plan change and does not charge the user" do
              expect(@subscription.flat_fee_applicable?).to be false
              travel_to(@originally_subscribed_at + 1.day)
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: same_plan_params.merge({ quantity: 1, perceived_price_cents: 599, perceived_upgrade_price_cents: 0 }),
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform
              expect(result[:success]).to eq(true)

              plan_change = @subscription.subscription_plan_changes.first
              expect(plan_change.quantity).to eq(1)
              expect(plan_change.perceived_price_cents).to eq 599
              expect(@subscription.reload.flat_fee_applicable?).to be true
            end
          end
        end

        context "when the membership was cancelled by the creator" do
          it "does not allow restarting the membership" do
            @subscription.update!(cancelled_by_buyer: false)

            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: existing_card_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq false
            expect(result[:error_message]).to eq "This subscription cannot be restarted."
            expect(@subscription.reload).not_to be_alive
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end

        context "when the product is deleted" do
          it "does not allow restarting the membership" do
            @product.mark_deleted!

            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: existing_card_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq false
            expect(result[:error_message]).to eq "This subscription cannot be restarted."
            expect(@subscription.reload).not_to be_alive
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end
      end

      describe "updating card after charge failure but before cancellation" do
        before do
          travel_to(@originally_subscribed_at + @subscription.period + 1.minute)
        end

        it "updates the card and charges the user" do
          old_card = @original_purchase.credit_card
          old_subscription_card = @subscription.credit_card
          old_user_card = @user.credit_card

          params = {
            price_id: @quarterly_product_price.external_id,
            variants: [@original_tier.external_id],
            quantity: 1,
            perceived_price_cents: @original_tier_quarterly_price.price_cents,
            perceived_upgrade_price_cents: @original_tier_quarterly_price.price_cents,
          }.merge(StripePaymentMethodHelper.success.to_stripejs_params(prepare_future_payments: true))

          expect do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform
          end.to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }.by(1)

          last_purchase = @subscription.last_successful_charge
          expect(last_purchase.id).not_to eq @original_purchase.id
          expect(last_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents
          expect(last_purchase.credit_card).not_to eq old_card
          expect(last_purchase.is_upgrade_purchase).to eq false

          expect(@subscription.reload.credit_card).to be
          expect(@subscription.credit_card).not_to eq old_subscription_card
          expect(@user.reload.credit_card).to be
          expect(@user.credit_card).to eq old_user_card
          expect(@subscription.reload.flat_fee_applicable?).to be false
        end

        it "applies any plan changes immediately" do
          expect do
            params = downgrade_recurrence_params.merge(perceived_upgrade_price_cents: downgrade_recurrence_params[:perceived_price_cents]).merge(StripePaymentMethodHelper.success.to_stripejs_params(prepare_future_payments: true))
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true
            expect(result[:success_message]).to eq "Your membership has been updated."

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.id).not_to eq @original_purchase.id
            expect(updated_purchase.price_cents).to eq @original_tier_monthly_price.price_cents
          end.not_to change { SubscriptionPlanChange.count }
          expect(@subscription.reload.flat_fee_applicable?).to be true
        end

        it "updates the card and charges the user correctly if seller has a connected Stripe account" do
          old_card = @original_purchase.credit_card
          old_subscription_card = @subscription.credit_card
          old_user_card = @user.credit_card

          stripe_connect_account = create(:merchant_account_stripe_connect, user: @subscription.link.user)
          @subscription.link.user.update_attribute(:check_merchant_account_is_linked, true)

          params = {
            price_id: @quarterly_product_price.external_id,
            variants: [@original_tier.external_id],
            quantity: 1,
            perceived_price_cents: @original_tier_quarterly_price.price_cents,
            perceived_upgrade_price_cents: @original_tier_quarterly_price.price_cents,
          }.merge(StripePaymentMethodHelper.success.to_stripejs_params(prepare_future_payments: true))

          expect do
            expect do
              Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
                ).perform
            end.to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }.by(1)
          end.to change { CreditCard.count }.by(1)

          last_purchase = @subscription.last_successful_charge
          expect(last_purchase.id).not_to eq @original_purchase.id
          expect(last_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents
          expect(last_purchase.credit_card).not_to eq old_card
          expect(last_purchase.merchant_account).to eq stripe_connect_account
          expect(last_purchase.is_upgrade_purchase).to eq false

          expect(@subscription.reload.credit_card).to be
          expect(@subscription.credit_card).not_to eq old_subscription_card
          expect(@user.reload.credit_card).to be
          expect(@user.credit_card).to eq old_user_card
          expect(@subscription.reload.flat_fee_applicable?).to be false
        end

        context "when the new card requires e-mandate" do
          let(:params) do
            {
              price_id: @quarterly_product_price.external_id,
              variants: [@original_tier.external_id],
              quantity: 1,
              perceived_price_cents: @original_tier_quarterly_price.price_cents,
              perceived_upgrade_price_cents: @original_tier_quarterly_price.price_cents,
            }.merge(StripePaymentMethodHelper.success_indian_card_mandate.to_stripejs_params(prepare_future_payments: true))
          end

          it "updates and charges the new card and returns proper SCA response" do
            old_card = @original_purchase.credit_card
            PostToPingEndpointsWorker.jobs.clear

            response = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(@subscription.reload.purchases.in_progress.not_is_original_subscription_purchase.count).to eq(1)
            expect(@subscription.credit_card.last_four_digits).to eq("0123")

            last_purchase = @subscription.purchases.last
            expect(last_purchase.id).not_to eq @original_purchase.id
            expect(last_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents
            expect(last_purchase.credit_card).not_to eq old_card
            expect(last_purchase.credit_card.last_four_digits).to eq("0123")
            expect(last_purchase.in_progress?).to be true
            expect(last_purchase.is_upgrade_purchase?).to eq false

            expect(response[:success]).to be true
            expect(response[:requires_card_action]).to be true
            expect(response[:client_secret]).to be_present
            expect(response[:purchase][:id]).to eq(last_purchase.external_id)
            expect(PostToPingEndpointsWorker.jobs.size).to eq(0)
          end
        end
      end

      context "changing the price on a PWYW tier" do
        before :each do
          travel_back
          setup_subscription(pwyw: true) # @original_purchase price is now $6.99
          travel_to(@originally_subscribed_at + 1.month)

          @params = {
            price_id: @quarterly_product_price.external_id,
            variants: [@original_tier.external_id],
            use_existing_card: true,
          }
        end

        context "to a price that is higher" do
          it "charges the user the difference and creates a new 'original' purchase with the new price" do
            params = @params.merge(
              price_range: 7_99,
              perceived_price_cents: 7_99,
              perceived_upgrade_price_cents: 3_38,
            )

            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.id).not_to eq @original_purchase.id
            expect(updated_purchase.displayed_price_cents).to eq 7_99
            expect(updated_purchase.purchase_state).to eq "not_charged"
            expect(@original_purchase.reload.is_archived_original_subscription_purchase).to eq true

            upgrade_purchase = @subscription.purchases.last
            expect(upgrade_purchase.id).not_to eq @original_purchase.id
            expect(upgrade_purchase.is_upgrade_purchase).to eq true
            expect(upgrade_purchase.total_transaction_cents).to eq 3_38
            expect(upgrade_purchase.displayed_price_cents).to eq 3_38
            expect(upgrade_purchase.price_cents).to eq 3_38
            expect(upgrade_purchase.total_transaction_cents).to eq 3_38
            expect(upgrade_purchase.fee_cents).to eq 124
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end

          context "when the card requires e-mandate" do
            before do
              indian_cc = create(:credit_card, user: @user, chargeable: create(:chargeable, card: StripePaymentMethodHelper.success_indian_card_mandate))
              @subscription.credit_card = indian_cc
              @subscription.save!
            end

            it "charges the difference and returns proper SCA response" do
              params = @params.merge(
                price_range: 7_99,
                perceived_price_cents: 7_99,
                perceived_upgrade_price_cents: 3_38,
              )
              PostToPingEndpointsWorker.jobs.clear

              response = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(@subscription.reload.purchases.in_progress.not_is_original_subscription_purchase.count).to eq(1)
              expect(@subscription.credit_card.last_four_digits).to eq("0123")

              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).not_to eq @original_purchase.id
              expect(updated_purchase.displayed_price_cents).to eq 7_99
              expect(updated_purchase.purchase_state).to eq "not_charged"
              expect(@original_purchase.reload.is_archived_original_subscription_purchase).to eq true

              upgrade_purchase = @subscription.purchases.last
              expect(upgrade_purchase.id).not_to eq @original_purchase.id
              expect(upgrade_purchase.is_upgrade_purchase).to eq true
              expect(upgrade_purchase.total_transaction_cents).to eq 3_38
              expect(upgrade_purchase.displayed_price_cents).to eq 3_38
              expect(upgrade_purchase.price_cents).to eq 3_38
              expect(upgrade_purchase.total_transaction_cents).to eq 3_38
              expect(upgrade_purchase.fee_cents).to eq 124
              expect(@subscription.reload.flat_fee_applicable?).to be true

              expect(response[:success]).to be true
              expect(response[:requires_card_action]).to be true
              expect(response[:client_secret]).to be_present
              expect(response[:purchase][:id]).to eq(@subscription.purchases.in_progress.last.external_id)
              expect(PostToPingEndpointsWorker.jobs.size).to eq(0)
            end
          end
        end

        context "to a price that is lower" do
          it "records that the plan should be changed and does not charge the user" do
            params = @params.merge(
              price_range: 5_99,
              perceived_price_cents: 5_99,
              perceived_upgrade_price_cents: 0,
            )

            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true
            expect(@original_purchase.errors.full_messages).to be_empty

            plan_change = @subscription.subscription_plan_changes.first
            expect(plan_change.tier).to eq @original_tier
            expect(plan_change.recurrence).to eq "quarterly"
            expect(plan_change.deleted_at).to be_nil
            expect(plan_change.perceived_price_cents).to eq 5_99

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.id).to eq @original_purchase.id
            expect(@original_purchase.reload.is_archived_original_subscription_purchase).to eq false
            expect(@original_purchase.variant_attributes).to eq [@original_tier]
            expect(@original_purchase.displayed_price_cents).to eq 6_99
            expect(@subscription.last_payment_option.price).to eq @quarterly_product_price

            expect(@subscription.reload.purchases.count).to eq 1
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end
        end
      end

      describe "switching to a PWYW tier" do
        before :each do
          @new_tier.update!(customizable_price: true)
        end

        context "when the price is above the suggested price" do
          let(:params) do
            {
              price_id: @yearly_product_price.external_id,
              variants: [@new_tier.external_id],
              price_range: 20_01,
              use_existing_card: true,
              perceived_price_cents: 20_01,
              perceived_upgrade_price_cents: 16_06,
            }
          end

          it "creates a new 'original' purchase with the new variant and price, including perceived_price_cents" do
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true
            expect(result[:success_message]).to eq "Your membership has been updated."

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.id).not_to eq @original_purchase.id
            expect(updated_purchase.variant_attributes).to eq [@new_tier]
            expect(updated_purchase.displayed_price_cents).to eq 20_01
            expect(updated_purchase.perceived_price_cents).to eq 20_01
            expect(updated_purchase.purchase_state).to eq "not_charged"
            expect(@subscription.last_payment_option.price).to eq @yearly_product_price
            expect(@original_purchase.reload.is_archived_original_subscription_purchase).to eq true
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end

          it "charges the pro-rated rate for the new variant for the remainder of the period" do
            expect do
              Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform
            end.to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }.by(1)

            upgrade_purchase = @subscription.purchases.last

            # The original purchase was 1 month ago, for a quarterly membership.
            # Expected cost should be quarterly price for new tier - 2/3 of
            # quarterly price for old tier:
            # $20.01 - ($5.99 * 0.67) = $20.01 - $3.94 = $16.06
            expect(upgrade_purchase.is_upgrade_purchase).to eq true
            expect(upgrade_purchase.total_transaction_cents).to eq 16_06
            expect(upgrade_purchase.displayed_price_cents).to eq 16_06
            expect(upgrade_purchase.price_cents).to eq 16_06
            expect(upgrade_purchase.total_transaction_cents).to eq 16_06
            expect(upgrade_purchase.fee_cents).to eq 287
          end
        end

        context "when the price is below the suggested price" do
          let(:params) do
            {
              price_id: @monthly_product_price.external_id,
              variants: [@new_tier.external_id],
              price_range: 5_01,
              use_existing_card: true,
              perceived_price_cents: 5_01,
              perceived_upgrade_price_cents: 0,
            }
          end

          it "does not change the variant or price immediately" do
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true
            expect(@original_purchase.errors.full_messages).to be_empty

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.id).to eq @original_purchase.id

            @original_purchase.reload
            expect(@original_purchase.variant_attributes).to eq [@original_tier]
            expect(@original_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents
            expect(@subscription.last_payment_option.price).to eq @quarterly_product_price
          end

          it "does not charge the user" do
            expect do
              Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform
            end.not_to change { @subscription.reload.purchases.not_is_original_subscription_purchase.count }
          end

          it "records that the plan should be changed at the end of the next billing period" do
            expect do
              Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform
            end.to change { @subscription.reload.subscription_plan_changes.count }.by(1)

            plan_change = @subscription.subscription_plan_changes.first
            expect(plan_change.tier).to eq @new_tier
            expect(plan_change.recurrence).to eq "monthly"
            expect(plan_change.deleted_at).to be_nil
            expect(plan_change.perceived_price_cents).to eq 5_01
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end
        end
      end

      describe "updating during a free trial" do
        let(:free_trial) { true }

        before do
          # don't enqueue sale notification for the upgrade purchase to facilitate testing
          allow_any_instance_of(Purchase).to receive(:send_notification_webhook)

          travel_to(@subscription.free_trial_ends_at - 1.day)
        end

        context "upgrading" do
          it "upgrades the user immediately and does not charge them" do
            expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)

            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: upgrade_tier_params.merge(perceived_upgrade_price_cents: 0),
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.id).not_to eq @original_purchase.id
            expect(updated_purchase.is_free_trial_purchase).to eq true
            expect(updated_purchase.purchase_state).to eq "not_charged"
            expect(updated_purchase.variant_attributes).to eq [@new_tier]
            expect(updated_purchase.displayed_price_cents).to eq 10_50
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end

          it "sends a subscription_updated notification" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: upgrade_tier_params.merge(perceived_upgrade_price_cents: 0),
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            new_original_purchase = @subscription.reload.original_purchase
            params = {
              type: "upgrade",
              effective_as_of: new_original_purchase.created_at.as_json,
              old_plan: {
                tier: { id: @original_tier.external_id, name: @original_tier.reload.name },
                recurrence: "quarterly",
                price_cents: @original_purchase.displayed_price_cents,
                quantity: 1,
              },
              new_plan: {
                tier: { id: @new_tier.external_id, name: @new_tier.name },
                recurrence: "quarterly",
                price_cents: @new_tier_quarterly_price.price_cents,
                quantity: 1,
              },
            }

            expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME, @subscription.id, params)
          end
        end

        context "downgrade" do
          it "downgrades the user immediately and does not charge them" do
            expect do
              Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: downgrade_tier_params.merge(perceived_upgrade_price_cents: 0),
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).not_to eq @original_purchase.id
              expect(updated_purchase.is_free_trial_purchase).to eq true
              expect(updated_purchase.purchase_state).to eq "not_charged"
              expect(updated_purchase.variant_attributes).to eq [@lower_tier]
              expect(updated_purchase.displayed_price_cents).to eq 4_00
              expect(@subscription.reload.flat_fee_applicable?).to be true
            end.not_to change { SubscriptionPlanChange.count }
          end

          it "sends a subscription_udpated notification with the correct effective time" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: downgrade_tier_params.merge(perceived_upgrade_price_cents: 0),
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            new_original_purchase = @subscription.reload.original_purchase
            params = {
              type: "downgrade",
              effective_as_of: new_original_purchase.created_at.as_json, # different from downgrading when not in free trial
              old_plan: {
                tier: { id: @original_tier.external_id, name: @original_tier.reload.name },
                recurrence: "quarterly",
                price_cents: @original_purchase.displayed_price_cents,
                quantity: 1,
              },
              new_plan: {
                tier: { id: @lower_tier.external_id, name: @lower_tier.name },
                recurrence: "quarterly",
                price_cents: @lower_tier_quarterly_price.price_cents,
                quantity: 1,
              },
            }

            expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME, @subscription.id, params)
          end
        end
      end

      describe "setting contact info" do
        it "sets the contact info on the original purchase" do
          result = Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: update_contact_info_params,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          expect(result[:success]).to eq true
          expect(@subscription.reload.flat_fee_applicable?).to be false

          @original_purchase.reload
          expect(@original_purchase.email).to eq email
          expect(@original_purchase.full_name).to eq "Jane Gumroad"
          expect(@original_purchase.street_address).to eq "100 Main St"
          expect(@original_purchase.city).to eq "San Francisco"
          expect(@original_purchase.state).to eq "CA"
          expect(@original_purchase.zip_code).to eq "12345"
          expect(@original_purchase.country).to eq "United States"
        end

        context "also updating plan" do
          it "sets the contact info on the new 'original' purchase as well" do
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: update_contact_info_params.merge(
                price_id: @yearly_product_price.external_id,
                perceived_price_cents: @original_tier_yearly_price.price_cents,
                perceived_upgrade_price_cents: @original_tier_yearly_upgrade_cost_after_one_month,
              ),
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true
            expect(@subscription.reload.flat_fee_applicable?).to be true

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.email).to eq email
            expect(updated_purchase.full_name).to eq "Jane Gumroad"
            expect(updated_purchase.street_address).to eq "100 Main St"
            expect(updated_purchase.city).to eq "San Francisco"
            expect(updated_purchase.state).to eq "CA"
            expect(updated_purchase.zip_code).to eq "12345"
            expect(updated_purchase.country).to eq "United States"
          end
        end
      end

      describe "updating pending plan changes" do
        let!(:plan_change) do
          create(:subscription_plan_change, subscription: @subscription)
        end

        context "when the plan has not changed" do
          it "does not delete pending plan changes" do
            params = {
              price_id: @quarterly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: @original_tier_quarterly_price.price_cents,
              perceived_upgrade_price_cents: 0,
            }

            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(plan_change.reload).not_to be_deleted
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end

        context "when upgrading" do
          it "deletes pending plan changes" do
            create(:subscription_plan_change, subscription: @subscription)

            params = {
              price_id: @yearly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: @original_tier_yearly_price.price_cents,
              perceived_upgrade_price_cents: @original_tier_yearly_upgrade_cost_after_one_month,
            }

            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(plan_change.reload).to be_deleted
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end
        end

        context "when downgrading" do
          let(:params) do
            {
              price_id: @monthly_product_price.external_id,
              variants: [@new_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: 5_00,
              perceived_upgrade_price_cents: 0,
            }
          end

          it "creates a new plan change" do
            expect do
              Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              new_plan_change = @subscription.reload.subscription_plan_changes.alive.first
              expect(new_plan_change.tier).to eq @new_tier
              expect(new_plan_change.recurrence).to eq "monthly"
              expect(new_plan_change.perceived_price_cents).to eq 5_00
            end.to change { @subscription.reload.subscription_plan_changes.count }.by(1)
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end

          it "deletes existing plan changes" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(plan_change.reload).to be_deleted
          end
        end
      end

      describe "purchase with a license" do
        let!(:license) { create(:license, purchase: @original_purchase) }

        context "when upgrading" do
          it "associates the license with the new subscription if updating succeeds" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: upgrade_tier_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            updated_purchase = @subscription.reload.original_purchase
            expect(license.reload.purchase_id).to eq updated_purchase.id
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end
        end

        context "when downgrading" do
          it "does not modify the license" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: downgrade_recurrence_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(license.reload.purchase_id).to eq @original_purchase.id
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end
        end

        context "when not changing plan" do
          it "does not modify the license" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: same_plan_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(license.reload.purchase_id).to eq @original_purchase.id
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end
      end

      describe "purchase with sent emails" do
        before do
          installment = create(:installment, link: @product, seller: @product.user, published_at: Time.current)
          @email_info = create(:creator_contacting_customers_email_info, installment:, purchase: @original_purchase)
        end

        context "when upgrading" do
          it "associates the email infos with the new subscription if updating succeeds" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: upgrade_tier_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            updated_purchase = @subscription.reload.original_purchase
            expect(@email_info.reload.purchase_id).to eq updated_purchase.id
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end
        end

        context "when downgrading" do
          it "does not modify the email infos" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: downgrade_recurrence_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(@email_info.reload.purchase_id).to eq @original_purchase.id
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end

          it "restores the comments with the original_purchase" do
            comment1 = create(:comment, purchase: @original_purchase)
            comment2 = create(:comment)
            comment3 = create(:comment, purchase: @original_purchase)

            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: downgrade_recurrence_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(comment1.reload.purchase_id).to eq(@original_purchase.id)
            expect(comment2.reload.purchase_id).to be_nil
            expect(comment3.reload.purchase_id).to eq(@original_purchase.id)
          end
        end

        context "when not changing plan" do
          it "does not modify the email infos" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: same_plan_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(@email_info.reload.purchase_id).to eq @original_purchase.id
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end
      end

      describe "membership has files" do
        it "creates a URL redirect for the new original purchase if upgrading" do
          travel_back
          setup_subscription(with_product_files: true)
          travel_to(@originally_subscribed_at + 1.month)

          Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: upgrade_tier_params,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          updated_purchase = @subscription.reload.original_purchase
          expect(updated_purchase.url_redirect).not_to be_nil
          expect(@subscription.reload.flat_fee_applicable?).to be true
        end
      end

      describe "updating when price has increased since subscribing" do
        before :each do
          @original_price = @original_tier_quarterly_price.price_cents
          @original_tier_quarterly_price.update!(price_cents: @original_price + 500)
        end

        context "not changing plan" do
          it "does not charge the user" do
            expect do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: same_plan_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true

              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).to eq @original_purchase.id
              expect(updated_purchase.displayed_price_cents).to eq @original_price
            end.not_to change { Purchase.count }
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end

        context "upgrading" do
          it "uses the preexisting subscription price to determine amount owed" do
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: upgrade_tier_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true

            upgrade_purchase = @subscription.reload.purchases.is_upgrade_purchase.last

            expect(upgrade_purchase.displayed_price_cents).to eq @new_tier_quarterly_upgrade_cost_after_one_month
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end
        end

        context "and subscription has no tier associated" do
          before :each do
            @original_purchase.variant_attributes = []
          end

          context "not changing plan" do
            it "does not charge the user" do
              expect do
                result = Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params: same_plan_params,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform

                expect(result[:success]).to eq true

                updated_purchase = @subscription.reload.original_purchase
                expect(updated_purchase.id).to eq @original_purchase.id
                expect(updated_purchase.displayed_price_cents).to eq @original_price
              end.not_to change { Purchase.count }
              expect(@subscription.reload.flat_fee_applicable?).to be false
            end
          end

          context "upgrading" do
            it "uses the preexisting subscription price to determine amount owed" do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: upgrade_tier_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true

              upgrade_purchase = @subscription.reload.purchases.is_upgrade_purchase.last

              expect(upgrade_purchase.displayed_price_cents).to eq @new_tier_quarterly_upgrade_cost_after_one_month
              expect(@subscription.reload.flat_fee_applicable?).to be true
            end
          end
        end
      end

      describe "updating when price has decreased since subscribing" do
        before :each do
          @original_price = @original_tier_quarterly_price.price_cents
          @original_tier_quarterly_price.update!(price_cents: @original_price - 200)
        end

        context "not changing plan" do
          it "does not charge the user or record a plan change" do
            expect do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: same_plan_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true

              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).to eq @original_purchase.id
              expect(updated_purchase.displayed_price_cents).to eq @original_price
              expect(@subscription.subscription_plan_changes.count).to eq 0
            end.not_to change { Purchase.count }
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end

        context "upgrading" do
          it "uses the preexisting subscription price to determine amount owed" do
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: upgrade_tier_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true

            upgrade_purchase = @subscription.reload.purchases.is_upgrade_purchase.last

            expect(upgrade_purchase.displayed_price_cents).to eq @new_tier_quarterly_upgrade_cost_after_one_month
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end
        end

        context "and subscription has no tier associated" do
          before :each do
            @original_purchase.variant_attributes = []
          end

          context "not changing plan" do
            it "does not charge the user or record a plan change" do
              expect do
                result = Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params: same_plan_params,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform

                expect(result[:success]).to eq true

                updated_purchase = @subscription.reload.original_purchase
                expect(updated_purchase.id).to eq @original_purchase.id
                expect(updated_purchase.displayed_price_cents).to eq @original_price
                expect(@subscription.subscription_plan_changes.count).to eq 0
              end.not_to change { Purchase.count }
              expect(@subscription.reload.flat_fee_applicable?).to be false
            end
          end

          context "upgrading" do
            it "uses the preexisting subscription price to determine amount owed" do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: upgrade_tier_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true

              upgrade_purchase = @subscription.reload.purchases.is_upgrade_purchase.last

              expect(upgrade_purchase.displayed_price_cents).to eq @new_tier_quarterly_upgrade_cost_after_one_month
              expect(@subscription.reload.flat_fee_applicable?).to be true
            end
          end
        end
      end

      describe "updating a test subscription" do
        context "upgrading" do
          it "marks both the upgrade purchase and new original purchase as 'test_successful'" do
            @product.update!(user: @user)
            @subscription.update!(is_test_subscription: true)
            @original_purchase.update!(purchase_state: "test_successful", seller: @user)

            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: upgrade_tier_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(@subscription.reload.flat_fee_applicable?).to be true

            updated_purchase = @subscription.reload.original_purchase
            upgrade_purchase = @subscription.purchases.last

            expect(updated_purchase.id).not_to eq @original_purchase.id
            expect(updated_purchase.purchase_state).to eq "test_successful"
            expect(upgrade_purchase.purchase_state).to eq "test_successful"
          end
        end
      end

      describe "updating a subscription with fixed duration" do
        before do
          @subscription.update!(charge_occurrence_count: 4)
        end

        it "allows updating credit card" do
          result = Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: update_card_params,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          expect(result[:success]).to eq true
          @subscription.reload
          @user.reload
          expect(@subscription.credit_card).to be
          expect(@subscription.credit_card).not_to eq @credit_card
          expect(@user.credit_card).to be
          expect(@user.credit_card).to eq @credit_card
          expect(@subscription.reload.flat_fee_applicable?).to be false
        end

        it "allows updating contact info" do
          result = Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: update_contact_info_params,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          expect(result[:success]).to eq true

          expect(@subscription.reload.flat_fee_applicable?).to be false

          @original_purchase.reload
          expect(@original_purchase.email).to eq email
          expect(@original_purchase.full_name).to eq "Jane Gumroad"
          expect(@original_purchase.street_address).to eq "100 Main St"
          expect(@original_purchase.city).to eq "San Francisco"
          expect(@original_purchase.state).to eq "CA"
          expect(@original_purchase.zip_code).to eq "12345"
          expect(@original_purchase.country).to eq "United States"
        end

        it "does not allow changing recurrence" do
          expect do
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: upgrade_recurrence_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq false
            expect(result[:error_message]).to eq "Changing plans for fixed-length subscriptions is not currently supported."
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end.not_to change { @subscription.reload.purchases.count }
        end

        it "does not allow changing tier" do
          expect do
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: upgrade_tier_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq false
            expect(result[:error_message]).to eq "Changing plans for fixed-length subscriptions is not currently supported."
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end.not_to change { @subscription.reload.purchases.count }
        end
      end

      describe "workflows" do
        before do
          # upgrade tier workflow
          upgrade_workflow = create(:variant_workflow, seller: @product.user, link: @product, base_variant: @new_tier)
          @upgrade_installment = create(:installment, link: @product, base_variant: @new_tier, workflow: upgrade_workflow, published_at: 1.day.ago)
          create(:installment_rule, installment: @upgrade_installment, delayed_delivery_time: 1.day)

          # downgrade tier workflow
          downgrade_workflow = create(:variant_workflow, seller: @product.user, link: @product, base_variant: @lower_tier)
          downgrade_installment = create(:installment, link: @product, base_variant: @lower_tier, workflow: downgrade_workflow, published_at: 1.day.ago)
          create(:installment_rule, installment: downgrade_installment, delayed_delivery_time: 1.day)
        end

        context "when upgrading tiers" do
          it "schedules workflow(s) associated with the new tier" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: upgrade_tier_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            purchase_id = @subscription.reload.original_purchase.id

            expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@upgrade_installment.id, 1, purchase_id, nil, nil)
          end
        end

        context "when downgrading tiers" do
          it "does not schedule workflow(s) associated with the new tier" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: downgrade_tier_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
          end
        end

        context "when not changing tiers" do
          it "does not schedule any workflows" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: same_plan_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
          end
        end
      end

      describe "error cases" do
        it "returns an error if missing or invalid variant" do
          invalid_params = [
            {
              price_id: @quarterly_product_price.external_id,
              variants: [],
              use_existing_card: true,
              perceived_price_cents: @original_tier_quarterly_price.price_cents,
              perceived_upgrade_price_cents: 0,
            },
            {
              price_id: @quarterly_product_price.external_id,
              use_existing_card: true,
              perceived_price_cents: @original_tier_quarterly_price.price_cents,
              perceived_upgrade_price_cents: 0,
            },
            {
              price_id: @quarterly_product_price.external_id,
              variants: nil,
              use_existing_card: true,
              perceived_price_cents: @original_tier_quarterly_price.price_cents,
              perceived_upgrade_price_cents: 0,
            },
            {
              price_id: @quarterly_product_price.external_id,
              variants: [create(:variant).external_id],
              use_existing_card: true,
              perceived_price_cents: @original_tier_quarterly_price.price_cents,
              perceived_upgrade_price_cents: 0,
            },
          ]

          invalid_params.each do |params|
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq false
            expect(result[:error_message]).to eq "Please select a valid tier and payment option."
            expect(@subscription.reload.original_purchase.variant_attributes).to eq [@original_tier]
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end

        it "returns an error if missing or invalid price_id" do
          invalid_params = [
            {
              price_id: nil,
              variants: [@original_tier.external_id],
              use_existing_card: true,
            },
            {
              price_id: "",
              variants: [@original_tier.external_id],
              use_existing_card: true,
            },
            {
              variants: [@original_tier.external_id],
              use_existing_card: true,
            },
            {
              price_id: create(:price, recurrence: "monthly").external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
            },
          ]

          invalid_params.each do |params|
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq false
            expect(result[:error_message]).to eq "Please select a valid tier and payment option."
            expect(@subscription.reload.price).to eq @quarterly_product_price
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end

        it "returns an error if missing or invalid perceived_price_cents if user is changing plan" do
          invalid_params = [
            {
              price_id: @monthly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: nil,
              perceived_upgrade_price_cents: 0,
            },
            {
              price_id: @monthly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_upgrade_price_cents: 0,
            },
            {
              price_id: @monthly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: "invalid",
              perceived_upgrade_price_cents: 0,
            },
          ]

          invalid_params.each do |params|
            @subscription.reload
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq false
            expect(result[:error_message]).to eq "The price just changed! Refresh the page for the updated price."
            expect(@subscription.reload.price).to eq @quarterly_product_price
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end

        it "returns an error if missing or invalid perceived_upgrade_price_cents if user is changing plan" do
          invalid_params = [
            {
              price_id: @monthly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: @original_tier_quarterly_price.price_cents,
              perceived_upgrade_price_cents: nil,
            },
            {
              price_id: @monthly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: @original_tier_quarterly_price.price_cents,
            },
            {
              price_id: @monthly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: @original_tier_quarterly_price.price_cents,
              perceived_upgrade_price_cents: "invalid",
            },
          ]

          invalid_params.each do |params|
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq false
            expect(result[:error_message]).to eq "The price just changed! Refresh the page for the updated price."
            expect(@subscription.reload.price).to eq @quarterly_product_price
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end

        describe "credit card errors" do
          context "when the user should be charged" do
            it "returns an error when using existing card that is invalid" do
              invalid_credit_card = create(:credit_card, chargeable: build(:chargeable, card: StripePaymentMethodHelper.success_charge_decline), user: @user)
              @subscription.update!(credit_card: invalid_credit_card)
              @user.update!(credit_card: invalid_credit_card)
              @original_purchase.update!(credit_card: invalid_credit_card)

              params = {
                price_id: @yearly_product_price.external_id,
                variants: [@new_tier.external_id],
                use_existing_card: true,
                perceived_price_cents: @new_tier_yearly_price.price_cents,
                perceived_upgrade_price_cents: @new_tier_yearly_upgrade_cost_after_one_month,
              }

              expect do
                result = Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params:,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform

                expect(result[:success]).to eq false
                expect(result[:error_message]).to eq("Your card was declined.")
                expect(@subscription.reload.original_purchase.variant_attributes).to eq [@original_tier]
                expect(@subscription.price).to eq @quarterly_product_price
                expect(@subscription.reload.flat_fee_applicable?).to be false
              end.not_to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }
            end

            it "returns an error when using a new card with invalid parameters" do
              params = {
                price_id: @yearly_product_price.external_id,
                variants: [@new_tier.external_id],
                perceived_price_cents: @new_tier_yearly_price.price_cents,
                perceived_upgrade_price_cents: @new_tier_yearly_upgrade_cost_after_one_month,
              }.merge(StripePaymentMethodHelper.decline.to_stripejs_params)

              expect do
                result = Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params:,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform

                expect(result[:success]).to eq false
                expect(result[:error_message]).to eq("Your card was declined.")
                expect(@subscription.reload.original_purchase.variant_attributes).to eq [@original_tier]
                expect(@subscription.price).to eq @quarterly_product_price
                expect(@subscription.credit_card).to eq @credit_card
                expect(@subscription.reload.flat_fee_applicable?).to be false
              end.not_to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }
            end

            context "coming from a card declined email" do
              it "does not enqueue declined card tasks" do
                allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_raise ChargeProcessorCardError, "unknown error"

                params = {
                  price_id: @yearly_product_price.external_id,
                  variants: [@original_tier.external_id],
                  use_existing_card: true,
                  declined: true,
                  perceived_price_cents: @original_tier_yearly_price.price_cents,
                  perceived_upgrade_price_cents: @original_tier_yearly_upgrade_cost_after_one_month,
                }

                expect(CustomerLowPriorityMailer).to_not receive(:subscription_card_declined)

                Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params:,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform
              end
            end
          end
        end

        describe "errors saving records" do
          before :each do
            allow_any_instance_of(PaymentOption).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)
          end
          let(:params) do
            {
              price_id: @yearly_product_price.external_id,
              variants: [@new_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: @new_tier_yearly_price.price_cents,
              perceived_upgrade_price_cents: @new_tier_yearly_upgrade_cost_after_one_month,
            }
          end

          it "rolls back the transaction" do
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq false

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.id).to eq @original_purchase.id
            expect(@original_purchase.reload.variant_attributes).to eq [@original_tier]
            expect(@original_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents
            expect(@subscription.reload.price).to eq @quarterly_product_price
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end

          context "when old plan price has changed" do
            it "does not apply the new price, but fully rolls back the transaction" do
              @original_tier_quarterly_price.update!(price_cents: 10_00)

              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq false

              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).to eq @original_purchase.id
              expect(@original_purchase.reload.variant_attributes).to eq [@original_tier]
              expect(@original_purchase.displayed_price_cents).to eq 5_99
              expect(@subscription.reload.flat_fee_applicable?).to be false
            end
          end
        end

        describe "PWYW errors" do
          it "returns an error if price is too low" do
            @new_tier.update!(customizable_price: true)

            params = {
              price_id: @yearly_product_price.external_id,
              variants: [@new_tier.external_id],
              price_range: 19_99,
              use_existing_card: true,
              perceived_price_cents: 19_99,
              perceived_upgrade_price_cents: 16_03,
            }

            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq false
            expect(result[:error_message]).to eq "Please enter an amount greater than or equal to the minimum."
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end

        describe "contact info errors" do
          it "returns an error if email is missing" do
            [nil, ""].each do |email|
              params = {
                price_id: @quarterly_product_price.external_id,
                variants: [@original_tier.external_id],
                use_existing_card: true,
                contact_info: {
                  email:,
                },
              }
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq false
              expect(result[:error_message]).to eq "Validation failed: valid email required"
              expect(@subscription.reload.flat_fee_applicable?).to be false
            end
          end
        end

        describe "perceived prices don't match" do
          context "when new subscription price doesn't match" do
            context "when upgrading" do
              it "returns an error" do
                params = {
                  price_id: @yearly_product_price.external_id,
                  variants: [@new_tier.external_id],
                  use_existing_card: true,
                  perceived_price_cents: 19_99,
                  perceived_upgrade_price_cents: @new_tier_yearly_upgrade_cost_after_one_month,
                }

                result = Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params:,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform

                expect(result[:success]).to eq false
                expect(result[:error_message]).to eq "The price just changed! Refresh the page for the updated price."
                expect(@subscription.reload.flat_fee_applicable?).to be false
              end
            end

            context "when downgrading" do
              it "returns an error" do
                params = {
                  price_id: @monthly_product_price.external_id,
                  variants: [@original_tier.external_id],
                  use_existing_card: true,
                  perceived_price_cents: 2_99,
                  perceived_upgrade_price_cents: 0,
                }

                result = Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params:,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform

                expect(result[:success]).to eq false
                expect(result[:error_message]).to eq "The price just changed! Refresh the page for the updated price."
                expect(@subscription.reload.flat_fee_applicable?).to be false
              end
            end
          end

          context "when upgrade purchase price doesn't match" do
            context "when upgrading" do
              it "returns an error" do
                params = {
                  price_id: @yearly_product_price.external_id,
                  variants: [@new_tier.external_id],
                  use_existing_card: true,
                  perceived_price_cents: @new_tier_yearly_price.price_cents,
                  perceived_upgrade_price_cents: 16_03,
                }

                result = Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params:,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform

                expect(result[:success]).to eq false
                expect(result[:error_message]).to eq "The price just changed! Refresh the page for the updated price."
                expect(@subscription.reload.flat_fee_applicable?).to be false
              end
            end

            context "when downgrading" do
              it "returns an error" do
                params = {
                  price_id: @monthly_product_price.external_id,
                  variants: [@original_tier.external_id],
                  use_existing_card: true,
                  perceived_price_cents: 3_00,
                  perceived_upgrade_price_cents: 1,
                }

                result = Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params:,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform

                expect(result[:success]).to eq false
                expect(result[:error_message]).to eq "The price just changed! Refresh the page for the updated price."
                expect(@subscription.reload.flat_fee_applicable?).to be false
              end
            end
          end
        end
      end

      describe "notifying buyer and creator on upgrade" do
        let(:params) do
          {
            price_id: @yearly_product_price.external_id,
            variants: [@new_tier.external_id],
            use_existing_card: true,
            perceived_price_cents: @new_tier_yearly_price.price_cents,
            perceived_upgrade_price_cents: @new_tier_yearly_upgrade_cost_after_one_month,
          }
        end

        it "emails an upgrade receipt to the buyer" do
          Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params:,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          upgrade_purchase = @subscription.purchases.is_upgrade_purchase.first

          expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(upgrade_purchase.id).on("critical")
        end

        it "notifies the creator" do
          mail_double = double
          allow(mail_double).to receive(:deliver_later)
          allow(ContactingCreatorMailer).to receive(:notify).and_return(mail_double)

          Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params:,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          upgrade_purchase = @subscription.purchases.is_upgrade_purchase.first

          expect(ContactingCreatorMailer).to have_received(:notify).with(upgrade_purchase.id)
        end
      end

      describe "notifying creator on downgrade" do
        it "notifies the creator" do
          mail_double = double
          allow(mail_double).to receive(:deliver_later)
          allow(ContactingCreatorMailer).to receive(:subscription_downgraded).and_return(mail_double)

          Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: downgrade_tier_params,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          expect(ContactingCreatorMailer).to have_received(:subscription_downgraded).with(@subscription.id, @subscription.subscription_plan_changes.first.id)
        end
      end

      describe "API notification" do
        before do
          # don't enqueue sale notification for the upgrade purchase to facilitate testing
          allow_any_instance_of(Purchase).to receive(:send_notification_webhook)
        end

        it "sends a subscription_updated notification when upgrading" do
          Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: upgrade_tier_params,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          new_original_purchase = @subscription.reload.original_purchase
          params = {
            type: "upgrade",
            effective_as_of: new_original_purchase.created_at.as_json,
            old_plan: {
              tier: { id: @original_tier.external_id, name: @original_tier.reload.name },
              recurrence: "quarterly",
              price_cents: @original_purchase.displayed_price_cents,
              quantity: 1,
            },
            new_plan: {
              tier: { id: @new_tier.external_id, name: @new_tier.name },
              recurrence: "quarterly",
              price_cents: @new_tier_quarterly_price.price_cents,
              quantity: 1,
            },
          }

          expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME, @subscription.id, params)
        end

        it "sends a subscription_updated notification when downgrading" do
          Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: downgrade_tier_params,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          params = {
            type: "downgrade",
            effective_as_of: @subscription.reload.end_time_of_last_paid_period.as_json,
            old_plan: {
              tier: { id: @original_tier.external_id, name: @original_tier.reload.name },
              recurrence: "quarterly",
              price_cents: @original_purchase.displayed_price_cents,
              quantity: 1,
            },
            new_plan: {
              tier: { id: @lower_tier.external_id, name: @lower_tier.name },
              recurrence: "quarterly",
              price_cents: @lower_tier_quarterly_price.price_cents,
              quantity: 1,
            },
          }

          expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME, @subscription.id, params)
        end

        it "sends a subscription_updated notification when changing PWYW price" do
          travel_back
          setup_subscription(pwyw: true) # @original_purchase price is now $6.99
          travel_to(@originally_subscribed_at + 1.month)

          upgrade_pwyw_price_params = {
            price_id: @quarterly_product_price.external_id,
            variants: [@original_tier.external_id],
            use_existing_card: true,
            price_range: 7_99,
            perceived_price_cents: 7_99,
            perceived_upgrade_price_cents: 3_38,
          }

          Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: upgrade_pwyw_price_params,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          new_original_purchase = @subscription.reload.original_purchase
          params = {
            type: "upgrade",
            effective_as_of: new_original_purchase.created_at.as_json,
            old_plan: {
              tier: { id: @original_tier.external_id, name: @original_tier.reload.name },
              recurrence: "quarterly",
              price_cents: @original_purchase.displayed_price_cents,
              quantity: 1,
            },
            new_plan: {
              tier: { id: @original_tier.external_id, name: @original_tier.reload.name },
              recurrence: "quarterly",
              price_cents: 799,
              quantity: 1,
            },
          }

          expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME, @subscription.id, params)
        end

        it "sends a subscription_updated notification when downgrading to a free plan" do
          @original_purchase.update!(offer_code: create(:offer_code, user: @product.user, products: [@product], amount_percentage: 100))

          Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: downgrade_tier_params.merge(perceived_price_cents: 0),
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          params = {
            type: "downgrade",
            effective_as_of: @subscription.reload.original_purchase.created_at.as_json,
            old_plan: {
              tier: { id: @original_tier.external_id, name: @original_tier.reload.name },
              recurrence: "quarterly",
              price_cents: @original_purchase.displayed_price_cents,
              quantity: 1,
            },
            new_plan: {
              tier: { id: @lower_tier.external_id, name: @lower_tier.name },
              recurrence: "quarterly",
              price_cents: 0,
              quantity: 1,
            },
          }

          expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME, @subscription.id, params)
        end

        it "does not send a subscription_updated notification when not changing plan" do
          Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: same_plan_params.merge(CardParamsSpecHelper.success.to_stripejs_params),
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          expect(PostToPingEndpointsWorker).not_to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME, @subscription.id)
        end
      end

      describe "enqueueing update integrations worker" do
        it "enqueues worker if new tier is different" do
          result = Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: upgrade_tier_params,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          expect(result[:success]).to eq true
          expect(UpdateIntegrationsOnTierChangeWorker).to have_enqueued_sidekiq_job(@subscription.id)
        end

        it "does not enqueue worker if tier did not change" do
          result = Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: upgrade_recurrence_params,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          expect(result[:success]).to eq true
          expect(UpdateIntegrationsOnTierChangeWorker.jobs.size).to eq(0)
        end
      end

      context "gifted subscription" do
        let(:gift) { create(:gift, giftee_email: "giftee@gumroad.com") }

        before do
          @subscription.update!(credit_card: create(:credit_card, user: @user))
        end

        context "when upgrading" do
          it "create new original purchase while keeping as a gift" do
            service = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: upgrade_tier_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            )

            expect do
              result = service.perform
              expect(result[:success]).to eq true
            end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :subscription_giftee_added_card)


            @subscription.reload
            expect(@subscription.gift?).to eq true
            expect(@subscription.original_purchase).to_not eq @original_purchase

            upgrade_purchase = @subscription.purchases.is_upgrade_purchase.last
            expect(upgrade_purchase.id).not_to eq @original_purchase.id
            expect(upgrade_purchase.is_upgrade_purchase).to eq true
          end
        end

        context "when giftee is adding a payment method" do
          before do
            @subscription.update!(credit_card: nil)
          end

          it "add payment method to the subscription and send a email notification" do
            service = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: update_card_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            )

            expect do
              result = service.perform
              expect(result[:success]).to eq true
            end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_giftee_added_card).with(@subscription.id)

            @subscription.reload
            expect(@subscription.gift?).to eq true
            expect(@subscription.credit_card).to be_present
            expect(@user.credit_card).to eq @credit_card
          end
        end
      end
    end

    context "non-tiered membership subscription" do
      before :each do
        @credit_card = create(:credit_card)
        @user_credit_card = create(:credit_card)
        @user = create(:user, credit_card: @user_credit_card)

        @product = create(:subscription_product_with_versions)
        @price_cents = @product.default_price_cents
        @yearly_price = create(:price, link: @product, recurrence: BasePrice::Recurrence::YEARLY, price_cents: 10_00)
        @subscription = create(:subscription, link: @product, credit_card: @credit_card, user: @user)
        @subscription.update!(flat_fee_applicable: false)
        # confirm that it's a monthly subscription
        expect(@subscription.recurrence).to eq "monthly"

        @originally_subscribed_at = Time.utc(2020, 04, 01)
        travel_to(@originally_subscribed_at) do
          @original_purchase = create(:purchase,
                                      is_original_subscription_purchase: true,
                                      link: @product,
                                      subscription: @subscription,
                                      price_cents: @product.default_price_cents,
                                      credit_card: @credit_card,
                                      variant_attributes: [@product.variants.first])
        end
      end

      after :each do
        travel_back
      end

      context "updating payment method" do
        before :each do
          # update the card while the current billing period is active
          travel_to(@originally_subscribed_at + 1.week)

          @params = {
            id: @subscription.external_id,
            price_id: @subscription.price.external_id,
            perceived_price_cents: @original_purchase.price_cents,
            perceived_upgrade_price_cents: 0,
            quantity: @original_purchase.quantity,
            variants: [@original_purchase.variant_attributes.first.external_id],
          }
        end

        context "to another card" do
          it "updates the card on file" do
            params = StripePaymentMethodHelper.success.to_stripejs_params(prepare_future_payments: true).merge(@params)

            expect do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true
              expect(result[:success_message]).to eq "Your membership has been updated."
              @subscription.reload
              @user.reload
              expect(@subscription.credit_card).to be
              expect(@subscription.credit_card).not_to eq @credit_card
              expect(@user.credit_card).to be
              expect(@user.credit_card).to eq @user_credit_card
              expect(@user.credit_card).not_to eq @credit_card
              expect(@subscription.reload.flat_fee_applicable?).to be false
            end.not_to change { @subscription.reload.purchases.count }
          end
        end

        context "to a card that requires an e-mandate" do
          it "updates the card on file" do
            params = StripePaymentMethodHelper.success_indian_card_mandate.to_stripejs_params(prepare_future_payments: true).merge(@params)

            expect do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true
              expect(@subscription.reload.credit_card).to be
              expect(@subscription.credit_card).not_to eq @credit_card
              expect(@user.reload.credit_card).to eq @user_credit_card
              expect(@user.credit_card).not_to eq @credit_card
              expect(@subscription.reload.flat_fee_applicable?).to be false
            end.not_to change { @subscription.reload.purchases.count }
          end
        end

        context "to PayPal via Braintree" do
          it "updates the card on file" do
            # generate braintree data
            transient_customer_store_key = BraintreeChargeableTransientCustomer.tokenize_nonce_to_transient_customer(
              Braintree::Test::Nonce::PayPalFuturePayment,
              "transient-customer-token-key",
            ).try(:transient_customer_store_key)

            params = {
              braintree_transient_customer_store_key: transient_customer_store_key,
              braintree_device_data: { dummy_session_id: "dummy" }.to_json,
            }.merge(@params)

            expect do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true
              expect(result[:success_message]).to eq "Your membership has been updated."

              @subscription.reload
              expect(@subscription.credit_card).to be
              expect(@subscription.credit_card).not_to eq @credit_card
              expect(@subscription.credit_card.card_type).to eq "paypal"
              expect(@user.reload.credit_card).not_to eq @subscription.credit_card
              expect(@subscription.reload.flat_fee_applicable?).to be false
            end.not_to change { @subscription.reload.purchases.count }
          end
        end
      end

      context "restarting" do
        let(:params) do
          {
            id: @subscription.external_id,
            price_id: @subscription.price.external_id,
            perceived_price_cents: @original_purchase.price_cents,
            perceived_upgrade_price_cents: 0,
            quantity: @original_purchase.quantity,
            use_existing_card: true,
            variants: [@original_purchase.variant_attributes.first.external_id],
          }
        end

        context "when subscription is pending cancellation (within the last billed period)" do
          before :each do
            @subscription.update!(cancelled_at: @originally_subscribed_at + 2.weeks, cancelled_by_buyer: true)
            travel_to(@originally_subscribed_at + 3.weeks)
          end

          it "restarts the membership and does not charge the user" do
            expect do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true
              expect(result[:success_message]).to eq "Membership restarted"
              expect(@subscription.reload.cancelled_at).to be_nil
              expect(@subscription.reload.flat_fee_applicable?).to be false
            end.not_to change { @subscription.reload.purchases.not_is_original_subscription_purchase.count }
          end
        end

        context "when subscription has been cancelled" do
          before :each do
            @subscription.update!(cancelled_at: @originally_subscribed_at + 2.weeks, cancelled_by_buyer: true)
            travel_to(@originally_subscribed_at + 5.weeks)
          end

          it "restarts the membership and charges the user" do
            expect do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: params.merge(perceived_upgrade_price_cents: @original_purchase.displayed_price_cents),
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true
              expect(result[:success_message]).to eq "Membership restarted"
              expect(@subscription.reload.cancelled_at).to be_nil
              expect(@subscription.reload.flat_fee_applicable?).to be true
            end.to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }.by(1)
          end
        end
      end

      context "changing plans" do
        context "upgrading recurrence" do
          let(:params) do
            {
              id: @subscription.external_id,
              price_id: @yearly_price.external_id,
              perceived_price_cents: @yearly_price.price_cents,
              perceived_upgrade_price_cents: 10_00,
              quantity: @original_purchase.quantity,
              variants: @original_purchase.variant_attributes,
              use_existing_card: true
            }
          end

          before { travel_to(@subscription.end_time_of_subscription + 1.day) }

          it "makes the change and charges the user" do
            expect do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform
              expect(result[:success]).to eq true
            end.to change { @subscription.reload.purchases.successful.count }.by(1)
               .and change { @subscription.purchases.not_charged.count }.by(1)

            expect(@subscription.price).to eq @yearly_price
            new_template_purchase = @subscription.original_purchase
            expect(new_template_purchase.id).not_to eq @original_purchase.id
            expect(new_template_purchase.displayed_price_cents).to eq 10_00
            last_charge = @subscription.purchases.successful.last
            expect(last_charge.id).not_to eq @original_purchase.id
            expect(last_charge.displayed_price_cents).to eq 10_00
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end

          it "does not send a subscription_updated notification" do
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform
            expect(result[:success]).to eq true

            expect(PostToPingEndpointsWorker).not_to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME, @subscription.id, anything)
          end
        end
      end
    end
  end
end
