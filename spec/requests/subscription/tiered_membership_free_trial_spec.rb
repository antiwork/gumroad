# frozen_string_literal: true

require "spec_helper"

describe "Tiered Membership Free Trial Spec", type: :system, js: true do
  include ManageSubscriptionHelpers
  include ProductWantThisHelpers

  let(:is_pwyw) { false }
  before :each do
    setup_subscription(free_trial: true, pwyw: is_pwyw)
    setup_subscription_token
  end

  context "during the free trial" do
    before do
      travel_to @subscription.free_trial_ends_at - 1.day
      setup_subscription_token
    end

    it "does not display payment blurb" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      expect(page).not_to have_text "You'll be charged"
    end

    it "does not display prices when toggling between options" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      choose "Second Tier"
      wait_for_ajax
      expect(page).not_to have_text "You'll be charged"

      choose "Tier 3"
      wait_for_ajax
      expect(page).not_to have_text "You'll be charged"

      choose "First Tier"
      wait_for_ajax
      expect(page).not_to have_text "You'll be charged"

      select("Yearly", from: "Recurrence")
      wait_for_ajax
      expect(page).not_to have_text "You'll be charged"

      select("Monthly", from: "Recurrence")
      wait_for_ajax
      expect(page).not_to have_text "You'll be charged"
    end

    context "upgrading" do
      it "upgrades the user immediatedly and does not charge them" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Second Tier"
        wait_for_ajax

        expect(page).not_to have_text "You'll be charged"

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")

        updated_purchase = @subscription.reload.original_purchase
        expect(updated_purchase.id).not_to eq @original_purchase.id
        expect(updated_purchase.is_free_trial_purchase).to eq true
        expect(updated_purchase.purchase_state).to eq "not_charged"
        expect(updated_purchase.variant_attributes).to eq [@new_tier]
        expect(updated_purchase.displayed_price_cents).to eq 10_50
      end

      context "when the initial purchase was free" do
        let(:is_pwyw) { true }
        before do
          @original_tier_quarterly_price.update!(price_cents: 0)
          @original_purchase.update!(displayed_price_cents: 0)
          @credit_card.destroy!
        end

        it "requires a credit card" do
          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"
          expect(page).not_to have_text "Pay with"

          choose "Second Tier"

          expect(page).to have_text "Pay with"
          expect(page).not_to have_text "You'll be charged" # no charge today
          fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])
          expect do
            click_on "Update membership"
            wait_for_ajax
            expect(page).to have_alert(text: "Your membership has been updated.")
          end.to change { @subscription.reload.purchases.count }.from(1).to(2)
             .and change { @subscription.original_purchase.id }
          expect(@subscription.original_purchase.displayed_price_cents).to eq 10_50
          expect(@subscription.original_purchase.variant_attributes).to eq [@new_tier]
        end
      end
    end

    context "downgrading" do
      it "downgrades the user immediately and does not charge them" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Tier 3"
        wait_for_ajax

        expect(page).not_to have_text "You'll be charged"

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")

        updated_purchase = @subscription.reload.original_purchase
        expect(updated_purchase.id).not_to eq @original_purchase.id
        expect(updated_purchase.is_free_trial_purchase).to eq true
        expect(updated_purchase.purchase_state).to eq "not_charged"
        expect(updated_purchase.variant_attributes).to eq [@lower_tier]
        expect(updated_purchase.displayed_price_cents).to eq 4_00
      end
    end

    context "updating credit card" do
      it "succeeds" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        click_on "Use a different card?"
        fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])
        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")
        expect(@subscription.reload.credit_card).not_to eq @credit_card
        expect(@subscription.credit_card).to be

        # Make sure recurring charges with the new card succeed
        expect do
          @subscription.charge!
        end.to change { @subscription.purchases.successful.count }.by(1)
      end

      it "succeeds with an SCA-enabled card" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        click_on "Use a different card?"
        fill_in_credit_card(number: StripePaymentMethodHelper.success_with_sca[:cc_number])
        click_on "Update membership"
        wait_for_ajax
        sleep 1
        within_sca_frame do
          find_and_click("button:enabled", text: /COMPLETE/)
        end

        expect(page).to have_alert(text: "Your membership has been updated.")
        expect(@subscription.reload.credit_card).not_to eq @credit_card
        expect(@subscription.credit_card).to be

        # Make sure recurring charges with the new card succeed
        expect do
          @subscription.charge!
        end.to change { @subscription.purchases.successful.count }.by(1)
      end
    end

    context "updating PWYW price" do
      let(:is_pwyw) { true }

      it "succeeds and does not charge the user when increasing price" do
        expect do
          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          pwyw_input = find_field "Name a fair price"
          pwyw_input.fill_in with: ""
          pwyw_input.fill_in with: "9.99"
          wait_for_ajax

          expect(page).not_to have_text "You'll be charged"

          click_on "Update membership"
          wait_for_ajax

          expect(page).to have_alert(text: "Your membership has been updated.")
          expect(@subscription.reload.original_purchase.displayed_price_cents).to eq 9_99
        end.not_to change { @subscription.purchases.successful.count }
      end

      it "succeeds and does not charge the user when decreasing price" do
        expect do
          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          pwyw_input = find_field "Name a fair price"
          pwyw_input.fill_in with: ""
          pwyw_input.fill_in with: "6.00"
          wait_for_ajax

          expect(page).not_to have_text "You'll be charged"

          click_on "Update membership"
          wait_for_ajax

          expect(page).to have_alert(text: "Your membership has been updated.")
          expect(@subscription.reload.original_purchase.displayed_price_cents).to eq 6_00
        end.not_to change { @subscription.purchases.successful.count }
      end
    end

    context "when overdue for charge" do
      it "charges the user" do
        travel_back
        travel_to(@subscription.free_trial_ends_at + 1.day) do
          setup_subscription_token
          expect do
            visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"
            click_on "Use a different card?"
            fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])
            click_on "Update membership"
            wait_for_ajax

            expect(page).to have_alert(text: "Your membership has been updated.")
          end.to change { @subscription.purchases.successful.count }.by(1)
        end
      end
    end
  end

  context "after the free trial" do
    before do
      travel_to(@subscription.free_trial_ends_at + 1.day) do
        # assume the subscription was charged properly at the end of the free trial
        @subscription.charge!
      end
      travel_to(@originally_subscribed_at + 1.month)
      setup_subscription_token
    end

    context "upgrading" do
      it "upgrades the user immediately and charges them" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Second Tier"

        expect(page).to have_content "You'll be charged US$6.02 today."

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")

        updated_purchase = @subscription.reload.original_purchase
        expect(updated_purchase.id).not_to eq @original_purchase.id
        expect(updated_purchase.is_free_trial_purchase).to eq true
        expect(updated_purchase.purchase_state).to eq "not_charged"
        expect(updated_purchase.variant_attributes).to eq [@new_tier]
        expect(updated_purchase.displayed_price_cents).to eq 10_50
        upgrade_charge = @subscription.purchases.successful.last
        expect(upgrade_charge.displayed_price_cents).to eq 6_02
      end
    end

    context "downgrading" do
      it "does not downgrade the user immediately" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Tier 3"
        wait_for_ajax

        expect(page).not_to have_text "You'll be charged"

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership will be updated at the end of your current billing cycle.")
        expect(@subscription.reload.purchases.count).to eq 2
        expect(@subscription.subscription_plan_changes.count).to eq 1
        expect(@subscription.original_purchase.variant_attributes).to eq [@original_tier]
      end
    end

    context "when the product no longer has free trial enabled" do
      before do
        @product.update!(free_trial_enabled: false, free_trial_duration_unit: nil, free_trial_duration_amount: nil)
      end

      it "allows the subscriber to modify the subscription" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Second Tier"

        expect(page).to have_content "You'll be charged US$6.02 today."

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")

        updated_purchase = @subscription.reload.original_purchase
        expect(updated_purchase.id).not_to eq @original_purchase.id
        expect(updated_purchase.is_free_trial_purchase).to eq true
        expect(updated_purchase.purchase_state).to eq "not_charged"
      end
    end
  end
end
