# frozen_string_literal: true

require "spec_helper"

describe "Subscription::UpdaterService – Tiered Membership Variant And Price Update Scenarios", :vcr do
  include ManageSubscriptionHelpers
  include CurrencyHelper

  describe "#perform" do
    context "tiered membership subscription" do
      before do
        setup_subscription

        @remote_ip = "11.22.33.44"
        @gumroad_guid = "abc123"
        travel_to(@originally_subscribed_at + 1.month)
      end

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

      let(:email) { generate(:email) }

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

      context "when variant has not changed" do
        context "nor has recurrence period" do
          it "does not change the variant or price" do
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
            expect(updated_purchase.variant_attributes).to eq [@original_tier]
            expect(updated_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents
          end

          it "does not charge the user" do
            expect do
              Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: same_plan_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform
            end.not_to change { @subscription.reload.purchases.not_is_original_subscription_purchase.count }
          end

          it "does not switch the subscription to new flat fee" do
            expect(@subscription.flat_fee_applicable?).to be false

            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: same_plan_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end

        context "but recurrence period has changed" do
          context "to a price that is the same as or less than the current price" do
            it "does not change the price on the original subscription" do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: downgrade_recurrence_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true

              @original_purchase.reload
              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).to eq @original_purchase.id
              expect(updated_purchase.variant_attributes).to eq [@original_tier]
              expect(updated_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents
            end

            it "does not charge the user" do
              expect do
                Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params: downgrade_recurrence_params,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform
              end.not_to change { @subscription.reload.purchases.not_is_original_subscription_purchase.count }
            end

            it "records that the user should be downgraded" do
              expect do
                Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params: downgrade_recurrence_params,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform
              end.to change { SubscriptionPlanChange.count }.by(1)

              plan_change = @subscription.subscription_plan_changes.first
              expect(plan_change.tier).to eq @original_tier
              expect(plan_change.recurrence).to eq "monthly"
              expect(plan_change.perceived_price_cents).to eq 3_00
            end

            it "switches the subscription to new flat fee" do
              expect(@subscription.flat_fee_applicable?).to be false

              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: downgrade_recurrence_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true
              expect(@subscription.reload.flat_fee_applicable?).to be true
            end
          end

          context "to a price that is greater than the current price" do
            it "creates a new 'original' subscription purchase and archives the old one" do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: upgrade_recurrence_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true

              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).not_to eq @original_purchase.id
              expect(updated_purchase.variant_attributes).to eq [@original_tier]
              expect(updated_purchase.displayed_price_cents).to eq 1000
              expect(updated_purchase.price_cents).to eq 1000
              expect(updated_purchase.total_transaction_cents).to eq 1000
              expect(updated_purchase.fee_cents).to eq 209
              expect(updated_purchase.purchase_state).to eq "not_charged"
              expect(@subscription.last_payment_option.price).to eq @yearly_product_price
              expect(@original_purchase.reload.is_archived_original_subscription_purchase).to eq true
            end

            it "charges the user on a pro-rated basis and upgrades them immediately" do
              expect do
                Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params: upgrade_recurrence_params,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform
              end.to change { @subscription.reload.purchases.not_is_original_subscription_purchase.count }.by(1)

              upgrade_purchase = @subscription.purchases.last

              expect(upgrade_purchase.is_upgrade_purchase).to eq true
              expect(upgrade_purchase.total_transaction_cents).to eq @original_tier_yearly_upgrade_cost_after_one_month
              expect(upgrade_purchase.displayed_price_cents).to eq @original_tier_yearly_upgrade_cost_after_one_month
              expect(upgrade_purchase.price_cents).to eq @original_tier_yearly_upgrade_cost_after_one_month
              expect(upgrade_purchase.total_transaction_cents).to eq @original_tier_yearly_upgrade_cost_after_one_month
              expect(upgrade_purchase.fee_cents).to eq 158
            end

            it "switches the subscription to new flat fee" do
              expect(@subscription.flat_fee_applicable?).to be false

              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: upgrade_recurrence_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true
              expect(@subscription.reload.flat_fee_applicable?).to be true
            end
          end
        end
      end

      context "when variant has changed" do
        context "but has the same recurrence period" do
          context "and is more expensive" do
            it "creates a new 'original' subscription purchase with the new variant and archives the old one" do
              Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: upgrade_tier_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              new_price_cents = @new_tier.prices.alive.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY).price_cents

              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).not_to eq @original_purchase.id
              expect(updated_purchase.variant_attributes).to eq [@new_tier]
              expect(updated_purchase.displayed_price_cents).to eq new_price_cents
              expect(updated_purchase.purchase_state).to eq "not_charged"
              expect(@subscription.last_payment_option.price).to eq @quarterly_product_price # no change
              expect(@original_purchase.reload.is_archived_original_subscription_purchase).to eq true
            end

            it "charges the pro-rated rate for the new variant for the remainder of the period" do
              expect do
                Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params: upgrade_tier_params,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform
              end.to change { @subscription.reload.purchases.not_is_original_subscription_purchase.count }.by(1)
                  .and change { @product.user.reload.balances.count }.by(1)

              upgrade_purchase = @subscription.purchases.last

              expect(upgrade_purchase.is_upgrade_purchase).to eq true
              expect(upgrade_purchase.total_transaction_cents).to eq @new_tier_quarterly_upgrade_cost_after_one_month
              expect(upgrade_purchase.displayed_price_cents).to eq @new_tier_quarterly_upgrade_cost_after_one_month
              expect(upgrade_purchase.price_cents).to eq @new_tier_quarterly_upgrade_cost_after_one_month
              expect(upgrade_purchase.total_transaction_cents).to eq @new_tier_quarterly_upgrade_cost_after_one_month
              expect(upgrade_purchase.fee_cents).to eq 164
              expect(upgrade_purchase.variant_attributes).to eq [@new_tier]

              # creator balance reflects upgrade purchase
              user_balances = @product.user.balances
              expect(user_balances.last.amount_cents).to eq @new_tier_quarterly_upgrade_cost_after_one_month - upgrade_purchase.fee_cents
            end

            it "switches the subscription to new flat fee" do
              expect(@subscription.flat_fee_applicable?).to be false

              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: upgrade_tier_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true
              expect(@subscription.reload.flat_fee_applicable?).to be true
            end
          end
        end

        context "and recurrence period has changed" do
          context "to a more expensive one" do
            let(:params) do
              {
                price_id: @yearly_product_price.external_id,
                variants: [@new_tier.external_id],
                use_existing_card: true,
                perceived_price_cents: @new_tier_yearly_price.price_cents,
                perceived_upgrade_price_cents: @new_tier_yearly_upgrade_cost_after_one_month,
              }
            end

            it "creates a new 'original' subscription purchase with the new variant and price and archives the old one" do
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
              expect(updated_purchase.variant_attributes).to eq [@new_tier]
              expect(updated_purchase.displayed_price_cents).to eq 2000
              expect(updated_purchase.price_cents).to eq 2000
              expect(updated_purchase.total_transaction_cents).to eq 2000
              expect(updated_purchase.fee_cents).to eq 338
              expect(updated_purchase.purchase_state).to eq "not_charged"
              expect(@subscription.last_payment_option.price).to eq @yearly_product_price
              expect(@original_purchase.reload.is_archived_original_subscription_purchase).to eq true
            end

            it "charges the user on a pro-rated basis and upgrades them immediately" do
              expect do
                Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params:,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform
              end.to change { @subscription.reload.purchases.not_is_original_subscription_purchase.count }.by(1)

              upgrade_purchase = @subscription.purchases.last

              expect(upgrade_purchase.is_upgrade_purchase).to eq true
              expect(upgrade_purchase.total_transaction_cents).to eq @new_tier_yearly_upgrade_cost_after_one_month
              expect(upgrade_purchase.displayed_price_cents).to eq @new_tier_yearly_upgrade_cost_after_one_month
              expect(upgrade_purchase.price_cents).to eq @new_tier_yearly_upgrade_cost_after_one_month
              expect(upgrade_purchase.total_transaction_cents).to eq @new_tier_yearly_upgrade_cost_after_one_month
              expect(upgrade_purchase.fee_cents).to eq 287
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
          end

          context "to a less expensive one" do
            let(:params) do
              {
                price_id: @monthly_product_price.external_id,
                variants: [@new_tier.external_id],
                use_existing_card: true,
                perceived_price_cents: 5_00,
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

              @original_purchase.reload
              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).to eq @original_purchase.id
              expect(@original_purchase.is_archived_original_subscription_purchase).to eq false
              expect(@original_purchase.variant_attributes).to eq [@original_tier]
              expect(@original_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents
              expect(@subscription.reload.price).to eq @quarterly_product_price
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
              expect(plan_change.perceived_price_cents).to eq 5_00
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
          end
        end
      end

      context "when purchase is taxable" do
        it "records the taxes due" do
          create(:zip_tax_rate, zip_code: nil, state: nil, country: Compliance::Countries::FRA.alpha2, combined_rate: 0.1, is_seller_responsible: false)

          @original_purchase.country = "France"
          @original_purchase.save!

          params = {
            price_id: @yearly_product_price.external_id,
            variants: [@new_tier.external_id],
            use_existing_card: true,
            perceived_price_cents: @new_tier_yearly_price.price_cents,
            perceived_upgrade_price_cents: @new_tier_yearly_upgrade_cost_after_one_month,
          }

          Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params:,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          updated_purchase = @subscription.reload.original_purchase
          expect(updated_purchase.id).not_to eq @original_purchase.id
          expect(updated_purchase.was_purchase_taxable).to eq true
          expect(updated_purchase.gumroad_tax_cents).to eq 2_00
          expect(updated_purchase.total_transaction_cents).to eq 22_00
        end
      end

      context "when original price has changed in the interim" do
        before :each do
          @original_tier_quarterly_price.update!(price_cents: 7_99)
        end

        context "upgrading" do
          let(:params) do
            {
              price_id: @yearly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: @original_tier_yearly_price.price_cents,
              perceived_upgrade_price_cents: @original_tier_yearly_upgrade_cost_after_one_month,
            }
          end

          it "uses the new price" do
            expect do
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
              expect(updated_purchase.variant_attributes).to eq [@original_tier]
              expect(updated_purchase.displayed_price_cents).to eq @original_tier_yearly_price.price_cents
              expect(@original_purchase.reload.is_archived_original_subscription_purchase).to eq true
            end.to change { @subscription.reload.purchases.not_is_original_subscription_purchase.count }.by(1)
          end

          it "charges the correct price difference" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            upgrade_purchase = @subscription.purchases.last

            expect(upgrade_purchase.is_upgrade_purchase).to eq true
            expect(upgrade_purchase.total_transaction_cents).to eq @original_tier_yearly_upgrade_cost_after_one_month
            expect(upgrade_purchase.displayed_price_cents).to eq @original_tier_yearly_upgrade_cost_after_one_month
            expect(upgrade_purchase.price_cents).to eq @original_tier_yearly_upgrade_cost_after_one_month
            expect(upgrade_purchase.total_transaction_cents).to eq @original_tier_yearly_upgrade_cost_after_one_month
            expect(upgrade_purchase.fee_cents).to eq 158
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
        end

        context "downgrading" do
          it "does not change the price or charge the user" do
            params = {
              price_id: @monthly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: 3_00,
              perceived_upgrade_price_cents: 0,
            }

            expect do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params:,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true

              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).to eq @original_purchase.id
              @original_purchase.reload
              expect(@original_purchase.variant_attributes).to eq [@original_tier]
              expect(@original_purchase.displayed_price_cents).to eq 5_99
            end.not_to change { @subscription.reload.purchases.not_is_original_subscription_purchase.count }
          end

          it "switches the subscription to new flat fee" do
            params = {
              price_id: @monthly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: 3_00,
              perceived_upgrade_price_cents: 0,
            }
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

          context "not changing plan" do
            it "does not change the price or charge the user" do
              params = {
                price_id: @quarterly_product_price.external_id,
                variants: [@original_tier.external_id],
                quantity: 1,
                use_existing_card: true,
                perceived_price_cents: @original_tier_quarterly_price.price_cents,
                perceived_upgrade_price_cents: 0,
              }

              expect do
                result = Subscription::UpdaterService.new(
                  subscription: @subscription,
                  gumroad_guid: @gumroad_guid,
                  params:,
                  logged_in_user: @user,
                  remote_ip: @remote_ip,
                ).perform

                expect(result[:success]).to eq true

                updated_purchase = @subscription.reload.original_purchase
                expect(updated_purchase.id).to eq @original_purchase.id
                @original_purchase.reload
                expect(@original_purchase.variant_attributes).to eq [@original_tier]
                expect(@original_purchase.displayed_price_cents).to eq 5_99
                expect(@subscription.reload.flat_fee_applicable?).to be false
              end.not_to change { @subscription.reload.purchases.not_is_original_subscription_purchase.count }
            end
          end
        end
      end

      context "when original purchase is not associated with a tier" do
        before :each do
          @original_purchase.variant_attributes = []
          @original_purchase.save!
        end

        it "does not treat it as a plan change if the default tier and original recurrence are selected" do
          expect do
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: same_plan_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true
            expect(@original_purchase.reload.variant_attributes).to eq [@original_tier]
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end.not_to change { Purchase.count }
        end

        context "upgrading" do
          it "treats it as an upgrade if a more expensive tier is selected" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: upgrade_tier_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.id).not_to eq @original_purchase.id
            expect(updated_purchase.variant_attributes).to eq [@new_tier]
            expect(updated_purchase.displayed_price_cents).to eq @new_tier_quarterly_price.price_cents
            expect(updated_purchase.purchase_state).to eq "not_charged"
            expect(@subscription.last_payment_option.price).to eq @quarterly_product_price # no change
            expect(@original_purchase.reload.is_archived_original_subscription_purchase).to eq true
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end

          it "treats it as an upgrade if a more expensive recurrence is selected" do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: upgrade_recurrence_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.id).not_to eq @original_purchase.id
            expect(updated_purchase.variant_attributes).to eq [@original_tier]
            expect(updated_purchase.displayed_price_cents).to eq @original_tier_yearly_price.price_cents
            expect(updated_purchase.purchase_state).to eq "not_charged"
            expect(@subscription.last_payment_option.price).to eq @yearly_product_price
            expect(@original_purchase.reload.is_archived_original_subscription_purchase).to eq true
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end

          context "default tier is sold out" do
            it "does not error" do
              @original_tier.update!(max_purchase_count: 0)

              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: upgrade_recurrence_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true

              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.variant_attributes).to eq [@original_tier]
            end
          end
        end

        context "downgrading" do
          it "treats it as a downgrade if a less expensive tier is selected" do
            expect do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: downgrade_tier_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true

              @original_purchase.reload
              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).to eq @original_purchase.id
              expect(updated_purchase.variant_attributes).to eq [@original_tier]
              expect(updated_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents

              plan_change = @subscription.subscription_plan_changes.first
              expect(plan_change.tier).to eq @lower_tier
              expect(plan_change.recurrence).to eq "quarterly"
              expect(plan_change.perceived_price_cents).to eq 4_00
            end.not_to change { @subscription.reload.purchases.not_is_original_subscription_purchase.count }
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end

          it "treats it as a downgrade if a less expensive recurrence is selected" do
            expect do
              result = Subscription::UpdaterService.new(
                subscription: @subscription,
                gumroad_guid: @gumroad_guid,
                params: downgrade_recurrence_params,
                logged_in_user: @user,
                remote_ip: @remote_ip,
              ).perform

              expect(result[:success]).to eq true

              @original_purchase.reload
              updated_purchase = @subscription.reload.original_purchase
              expect(updated_purchase.id).to eq @original_purchase.id
              expect(updated_purchase.variant_attributes).to eq [@original_tier]
              expect(updated_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents

              plan_change = @subscription.subscription_plan_changes.first
              expect(plan_change.tier).to eq @original_tier
              expect(plan_change.recurrence).to eq "monthly"
              expect(plan_change.perceived_price_cents).to eq 3_00
              expect(@subscription.reload.flat_fee_applicable?).to be true
            end.not_to change { @subscription.reload.purchases.not_is_original_subscription_purchase.count }
          end
        end
      end

      context "with VAT" do
        before :each do
          @remote_ip = "2.47.255.255" # Italy
          create(:zip_tax_rate, country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)
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

        context "when the original purchase was not charged VAT" do
          it "does not charge VAT even if has EU IP address" do
            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true

            # updated original purchase has correct taxes
            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.gumroad_tax_cents).to eq 0

            # upgrade purchase has correct taxes
            last_purchase = @subscription.purchases.last
            expect(last_purchase.gumroad_tax_cents).to eq 0
          end
        end

        context "when the original purchase was charged VAT" do
          it "uses the original purchase's country and VAT" do
            travel_back
            setup_subscription_with_vat # French VAT of 20%
            travel_to(@originally_subscribed_at + 1.month)

            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true

            # updated original purchase has correct taxes - $20 * 0.20 = $4
            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.gumroad_tax_cents).to eq 4_00
            expect(updated_purchase.total_transaction_cents).to eq 24_00
            expect(updated_purchase.purchase_sales_tax_info.country_code).to eq "FR"
            expect(updated_purchase.purchase_sales_tax_info.ip_address).to eq "2.16.255.255"

            # upgrade purchase has correct taxes - $16.05 * 0.20 = $3.21
            last_purchase = @subscription.purchases.last
            expect(last_purchase.displayed_price_cents).to eq @new_tier_yearly_upgrade_cost_after_one_month
            expect(last_purchase.total_transaction_cents).to eq 19_26
            expect(last_purchase.gumroad_tax_cents).to eq 3_21
            expect(last_purchase.purchase_sales_tax_info.country_code).to eq "FR"
            expect(last_purchase.purchase_sales_tax_info.ip_address).to eq "2.16.255.255"
          end
        end
      end

      context "updating at different times" do
        let(:params) do
          # more expensive tier and recurrence
          {
            price_id: @yearly_product_price.external_id,
            variants: [@new_tier.external_id],
            use_existing_card: true,
            perceived_price_cents: @new_tier_yearly_price.price_cents,
          }
        end

        it "charges the correct amount a day into the current period" do
          travel_to(@originally_subscribed_at + 1.hour) # rounds to end of day

          expect do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: params.merge(perceived_upgrade_price_cents: 14_08),
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform
          end.to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }.by(1)

          upgrade_purchase = @subscription.purchases.last

          # New plan price is $20/year. Prorated discount should be:
          # original price * (1 - 1.day.to_d/3.months) = $5.99 * (1 - 0.01095) = $5.92
          # Expected cost should be: $20 - $5.92 = $14.08
          expect(upgrade_purchase.is_upgrade_purchase).to eq true
          expect(upgrade_purchase.total_transaction_cents).to eq 14_08
          expect(upgrade_purchase.displayed_price_cents).to eq 14_08
          expect(upgrade_purchase.price_cents).to eq 14_08
          expect(upgrade_purchase.total_transaction_cents).to eq 14_08
          expect(upgrade_purchase.fee_cents).to eq 262
        end

        it "charges the correct amount halfway through the current period" do
          travel_to(@originally_subscribed_at + @subscription.period.to_i / 2)

          expect do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: params.merge(perceived_upgrade_price_cents: 17_04),
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform
          end.to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }.by(1)

          upgrade_purchase = @subscription.purchases.last

          # New plan price is $20/year. Prorated discount should be:
          # original price * (Time.current.end_of_day - @originally_subscribed_at) / @subscription.current_billing_period_seconds = $2.96
          # Expected cost should be: $20 - $2.96 = $17.04
          expect(upgrade_purchase.is_upgrade_purchase).to eq true
          expect(upgrade_purchase.total_transaction_cents).to eq 17_04
          expect(upgrade_purchase.displayed_price_cents).to eq 17_04
          expect(upgrade_purchase.price_cents).to eq 17_04
          expect(upgrade_purchase.total_transaction_cents).to eq 17_04
          expect(upgrade_purchase.fee_cents).to eq 300
        end

        it "charges the correct amount 3/4 through the current period" do
          travel_to(@originally_subscribed_at + @subscription.period.to_i * 3 / 4)

          expect do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: params.merge(perceived_upgrade_price_cents: 18_55),
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform
          end.to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }.by(1)

          upgrade_purchase = @subscription.purchases.last

          # New plan price is $20/year. Prorated discount should be:
          # original price * (Time.current.end_of_day - @originally_subscribed_at) / @subscription.current_billing_period_seconds = $1.45
          # Expected cost should be: $20 - $1.45 = $18.55
          expect(upgrade_purchase.is_upgrade_purchase).to eq true
          expect(upgrade_purchase.total_transaction_cents).to eq 18_55
          expect(upgrade_purchase.displayed_price_cents).to eq 18_55
          expect(upgrade_purchase.price_cents).to eq 18_55
          expect(upgrade_purchase.total_transaction_cents).to eq 18_55
          expect(upgrade_purchase.fee_cents).to eq 319
        end

        it "charges the correct amount a day before the current period ends" do
          travel_to(@subscription.end_time_of_subscription - 1.day - 1.hour)

          expect do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: params.merge(perceived_upgrade_price_cents: 19_93),
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform
          end.to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }.by(1)

          upgrade_purchase = @subscription.purchases.last

          # New plan price is $20/year. Prorated discount should be:
          # original price * (Time.current.end_of_day - @originally_subscribed_at) / @subscription.current_billing_period_seconds = $0.07
          # Expected cost should be: $20 - $0.07 = $19.93
          expect(upgrade_purchase.is_upgrade_purchase).to eq true
          expect(upgrade_purchase.total_transaction_cents).to eq 19_93
          expect(upgrade_purchase.displayed_price_cents).to eq 19_93
          expect(upgrade_purchase.price_cents).to eq 19_93
          expect(upgrade_purchase.total_transaction_cents).to eq 19_93
          expect(upgrade_purchase.fee_cents).to eq 337
        end

        it "charges the correct amount when the user upgrades within 3 minutes of purchase" do
          # typically this would result in a double charge error. For an upgrade purchase,
          # we should allow the additional charge.
          travel_to(@originally_subscribed_at + 2.minutes)

          expect do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @original_purchase.browser_guid, # trigger double purchase check
              params: params.merge(perceived_upgrade_price_cents: 14_08),
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform
          end.to change { @subscription.reload.purchases.successful.not_is_original_subscription_purchase.count }.by(1)

          upgrade_purchase = @subscription.purchases.last

          # New plan price is $20/year. Prorated discount should be:
          # original price * (1 - 1.day.to_d/3.months) = $5.99 * (1 - 0.01095) = $5.92
          # Expected cost should be: $20 - $5.92 = $14.08
          expect(upgrade_purchase.is_upgrade_purchase).to eq true
          expect(upgrade_purchase.total_transaction_cents).to eq 14_08
          expect(upgrade_purchase.displayed_price_cents).to eq 14_08
          expect(upgrade_purchase.price_cents).to eq 14_08
          expect(upgrade_purchase.total_transaction_cents).to eq 14_08
          expect(upgrade_purchase.fee_cents).to eq 262
        end
      end

      context "updating when prorated upgrade charge is less than product minimum price" do
        it "rounds up to the minimum product price ($0.99)" do
          @new_tier_quarterly_price.update!(price_cents: 6_25)

          params = {
            price_id: @quarterly_product_price.external_id,
            variants: [@new_tier.external_id],
            use_existing_card: true,
            perceived_price_cents: @new_tier_quarterly_price.price_cents,
            perceived_upgrade_price_cents: 99,
          }

          travel_to(@originally_subscribed_at + 1.hour) # rounds to end of day

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

          # New plan price is $6.25/quarter. Prorated discount should be:
          # original price * (1 - 1.day.to_d/3.months) = $5.99 * (1 - 0.01095) = $5.92
          # Expected cost should be: $6.25 - $5.92 = $0.33, but we round up to $0.99
          expect(upgrade_purchase.is_upgrade_purchase).to eq true
          expect(upgrade_purchase.total_transaction_cents).to eq 99
          expect(upgrade_purchase.displayed_price_cents).to eq 99
          expect(upgrade_purchase.price_cents).to eq 99
          expect(upgrade_purchase.total_transaction_cents).to eq 99
          expect(upgrade_purchase.fee_cents).to eq 93
        end

        context "for a product in non-USD currency" do
          it "rounds up to the minimum product price in that currency" do
            currency = "eur"
            change_membership_product_currency_to(@product, currency)
            set_tier_price_difference_below_min_upgrade_price(currency)

            params = {
              price_id: @quarterly_product_price.external_id,
              variants: [@new_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: @new_tier_quarterly_price.price_cents,
              perceived_upgrade_price_cents: @min_price_in_currency,
            }

            travel_to(@originally_subscribed_at + 2.minutes)

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

            expect(upgrade_purchase.displayed_price_cents).to eq @min_price_in_currency
            expect(@subscription.reload.original_purchase.displayed_price_cents).to eq @new_price
          end
        end
      end

      context "not updating variant, but current variant is no longer available" do
        let(:params) do
          {
            price_id: @yearly_product_price.external_id,
            variants: [@original_tier.external_id],
            use_existing_card: true,
            perceived_price_cents: @original_tier_yearly_price.price_cents,
            perceived_upgrade_price_cents: @original_tier_yearly_upgrade_cost_after_one_month,
          }
        end

        context "because it has been deleted" do
          it "still allows the user to select that variant" do
            @original_tier.mark_deleted!

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
            expect(updated_purchase.variant_attributes).to eq [@original_tier]
            expect(updated_purchase.displayed_price_cents).to eq @original_tier_yearly_price.price_cents
            expect(@original_purchase.reload.is_archived_original_subscription_purchase).to eq true
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end
        end

        context "because it is sold out" do
          it "still allows the user to select that variant" do
            @original_tier.update!(max_purchase_count: 1)

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
            expect(updated_purchase.variant_attributes).to eq [@original_tier]
            expect(updated_purchase.displayed_price_cents).to eq @original_tier_yearly_price.price_cents
            expect(@original_purchase.reload.is_archived_original_subscription_purchase).to eq true
            expect(@subscription.reload.flat_fee_applicable?).to be true
          end
        end
      end

      context "when current recurrence is no longer available" do
        before :each do
          @quarterly_product_price.mark_deleted!
          @original_tier_quarterly_price.mark_deleted!
        end

        context "and user is not updating recurrence" do
          it "still allows the user to select that recurrence" do
            params = {
              price_id: @quarterly_product_price.external_id,
              variants: [@original_tier.external_id],
              quantity: 1,
              use_existing_card: true,
              perceived_price_cents: @original_tier_quarterly_price.price_cents,
              perceived_upgrade_price_cents: 0,
            }

            result = Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params:,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform

            expect(result[:success]).to eq true

            updated_purchase = @subscription.reload.original_purchase
            expect(updated_purchase.id).to eq @original_purchase.id
            expect(updated_purchase.variant_attributes).to eq [@original_tier]
            expect(updated_purchase.displayed_price_cents).to eq @original_tier_quarterly_price.price_cents
            expect(@subscription.reload.flat_fee_applicable?).to be false
          end
        end

        context "and user is updating recurrence" do
          it "does not error" do
            params = {
              price_id: @yearly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: @original_tier_yearly_price.price_cents,
              perceived_upgrade_price_cents: @original_tier_yearly_upgrade_cost_after_one_month,
            }

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
        end
      end

      context "events" do
        before :each do
          create(:purchase_event, purchase: @original_purchase)
        end

        it "creates purchase events when upgrading" do
          Subscription::UpdaterService.new(
            subscription: @subscription,
            gumroad_guid: @gumroad_guid,
            params: upgrade_tier_params,
            logged_in_user: @user,
            remote_ip: @remote_ip,
          ).perform

          updated_purchase_events = @subscription.reload.original_purchase.events
          upgrade_purchase_events = @subscription.purchases.is_upgrade_purchase.first.events

          expect(updated_purchase_events.size).to eq 1
          expect(upgrade_purchase_events.size).to eq 1
          expect(updated_purchase_events.first.price_cents).to eq @new_tier_quarterly_price.price_cents
          expect(upgrade_purchase_events.first.price_cents).to eq @new_tier_quarterly_upgrade_cost_after_one_month
          expect(updated_purchase_events.first.is_recurring_subscription_charge).to eq false
          expect(upgrade_purchase_events.first.is_recurring_subscription_charge).to eq false
        end

        it "does not create a purchase event when not changing plan" do
          expect do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: same_plan_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform
          end.not_to change { Event.purchase.count }
        end

        it "does not create a purchase event when downgrading" do
          expect do
            Subscription::UpdaterService.new(
              subscription: @subscription,
              gumroad_guid: @gumroad_guid,
              params: downgrade_tier_params,
              logged_in_user: @user,
              remote_ip: @remote_ip,
            ).perform
          end.not_to change { Event.purchase.count }
        end
      end
    end
  end
end
