# frozen_string_literal: true

require "spec_helper"

describe "Tiered Membership Offer code Spec", type: :system, js: true do
  include ManageSubscriptionHelpers

  context "when the subscription has an offer code applied" do
    let(:offer_code) { create(:universal_offer_code, amount_cents: 200) }

    before do
      setup_subscription(offer_code:, is_multiseat_license: true)
      travel_to(@originally_subscribed_at + 1.month)
      setup_subscription_token
    end

    it "applies the same offer code when upgrading" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      choose "Second Tier"

      # shows the prorated price to be charged today
      expect(page).to have_text "You'll be charged US$5.87"

      click_on "Update membership"
      wait_for_ajax
      expect(page).to have_alert(text: "Your membership has been updated.")

      expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 5_87
      expect(@subscription.original_purchase.variant_attributes).to eq [@new_tier]
      expect(@subscription.original_purchase.offer_code_id).to eq offer_code.id
    end

    it "applies the same offer code when downgrading" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      choose @lower_tier.name

      expect(page).not_to have_text "You'll be charged"

      expect do
        click_on "Update membership"
        wait_for_ajax
        expect(page).to have_alert(text: "Your membership will be updated at the end of your current billing cycle.")
      end.to change { SubscriptionPlanChange.count }.from(0).to(1)

      plan_change = @subscription.subscription_plan_changes.first
      expect(plan_change.perceived_price_cents).to eq 2_00

      # ensure offer code is applied appropriately
      travel_back
      travel_to @subscription.end_time_of_subscription + 1.hour do
        expect do
          RecurringChargeWorker.new.perform(@subscription.id)
        end.to change { @subscription.reload.original_purchase.id }

        expect(@subscription.offer_code).to eq offer_code
      end
    end

    it "applies the code correctly when changing the number of seats" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      fill_in "Seats", with: 2
      click_on "Update membership"
      wait_for_ajax
      expect(page).to have_alert(text: "Your membership has been updated.")

      @subscription.reload
      expect(@subscription.purchases.last.displayed_price_cents).to eq 5_35
      expect(@subscription.original_purchase.displayed_price_cents).to eq 7_98
      expect(@subscription.original_purchase.quantity).to eq 2
      expect(@subscription.original_purchase.offer_code_id).to eq offer_code.id

      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      fill_in "Seats", with: 1
      click_on "Update membership"
      wait_for_ajax
      expect(page).to have_alert(text: "Your membership will be updated at the end of your current billing cycle.")

      plan_change = @subscription.subscription_plan_changes.first
      expect(plan_change.perceived_price_cents).to eq 3_99
      expect(plan_change.quantity).to eq 1
      expect(@subscription.original_purchase.offer_code_id).to eq offer_code.id
    end

    context "for a PWYW product" do
      before do
        [@original_tier, @new_tier, @lower_tier].each do |tier|
          tier.update!(customizable_price: true)
        end
        @original_purchase.update!(displayed_price_cents: 7_50)
      end

      it "applies the code correctly when increasing the PWYW amount" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        expect(page).to have_field("Name a fair price", with: "7.50")

        fill_in "Name a fair price", with: "9.50"
        wait_for_ajax
        expect(page).to have_text "You'll be charged US$4.55"

        click_on "Update membership"
        wait_for_ajax
        expect(page).to have_alert(text: "Your membership has been updated.")

        expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 4_55
        expect(@subscription.original_purchase.displayed_price_cents).to eq 9_50
        expect(@subscription.original_purchase.offer_code_id).to eq offer_code.id
      end

      it "applies the code correctly when decreasing the PWYW amount" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        fill_in "Name a fair price", with: "5.50"
        wait_for_ajax
        expect(page).not_to have_text "You'll be charged"

        expect do
          click_on "Update membership"
          wait_for_ajax
          expect(page).to have_alert(text: "Your membership will be updated at the end of your current billing cycle.")
        end.to change { SubscriptionPlanChange.count }.from(0).to(1)

        plan_change = @subscription.subscription_plan_changes.first
        expect(plan_change.perceived_price_cents).to eq 5_50
      end

      it "applies the offer code correctly when upgrading tiers" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Second Tier"

        fill_in "Name a fair price", with: "11.50"
        wait_for_ajax
        expect(page).to have_text "You'll be charged US$6.55"

        click_on "Update membership"
        wait_for_ajax
        expect(page).to have_alert(text: "Your membership has been updated.")

        expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 6_55
        expect(@subscription.original_purchase.displayed_price_cents).to eq 11_50
        expect(@subscription.original_purchase.offer_code_id).to eq offer_code.id
        expect(@subscription.original_purchase.variant_attributes).to eq [@new_tier]
      end

      it "applies the offer code correctly when downgrading tiers" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose @lower_tier.name

        fill_in "Name a fair price", with: "2.50"
        wait_for_ajax
        expect(page).not_to have_text "You'll be charged"

        expect do
          click_on "Update membership"
          wait_for_ajax
          expect(page).to have_alert(text: "Your membership will be updated at the end of your current billing cycle.")
        end.to change { SubscriptionPlanChange.count }.from(0).to(1)

        plan_change = @subscription.subscription_plan_changes.first
        expect(plan_change.perceived_price_cents).to eq 2_50

        # ensure offer code is applied appropriately
        travel_back
        travel_to @subscription.end_time_of_subscription + 1.hour do
          expect do
            RecurringChargeWorker.new.perform(@subscription.id)
          end.to change { @subscription.reload.original_purchase.id }

          expect(@subscription.offer_code).to eq offer_code
        end
      end

      it "applies the code correctly when changing the number of seats" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        fill_in "Seats", with: 2
        click_on "Update membership"
        wait_for_ajax
        expect(page).to have_alert(text: "Your membership has been updated.")

        @subscription.reload
        expect(@subscription.purchases.last.displayed_price_cents).to eq 10_05
        expect(@subscription.original_purchase.displayed_price_cents).to eq 15_00
        expect(@subscription.original_purchase.quantity).to eq 2
        expect(@subscription.original_purchase.offer_code_id).to eq offer_code.id

        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        fill_in "Seats", with: 1
        click_on "Update membership"
        wait_for_ajax
        expect(page).to have_alert(text: "Your membership will be updated at the end of your current billing cycle.")

        plan_change = @subscription.subscription_plan_changes.first
        expect(plan_change.perceived_price_cents).to eq 7_50
        expect(plan_change.quantity).to eq 1
        expect(@subscription.original_purchase.offer_code_id).to eq offer_code.id
      end
    end

    context "and the price has changed since the subscription was purchased" do
      it "correctly applies the offer code when restarting an expired membership" do
        @original_tier_quarterly_price.update!(price_cents: @original_tier_quarterly_price.price_cents + 500)
        ended_at = @subscription.end_time_of_subscription
        @subscription.update!(
          cancelled_at: ended_at,
          deactivated_at: ended_at,
          cancelled_by_buyer: true,
          token_expires_at: ended_at + 2.days
        )

        travel_back
        travel_to(ended_at + 1.day)

        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        # shows the correct price on the current plan
        expect(page).to have_radio_button("First Tier", checked: true, text: "$5.99 $3.99")

        # shows the price to be charged today
        expect(page).to have_text "You'll be charged US$3.99"

        click_on "Restart membership"
        wait_for_ajax
        expect(page).to have_alert(text: "Membership restarted")

        expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 3_99
      end
    end

    context "but the offer code is now deleted" do
      before do
        offer_code.mark_deleted!
      end

      it "does not apply the offer code when upgrading tiers" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Second Tier"

        # shows the prorated price without discount to be charged today
        expect(page).to have_text "You'll be charged US$7.87"

        click_on "Update membership"
        wait_for_ajax
        expect(page).to have_alert(text: "Your membership has been updated.")

        expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 7_87
        expect(@subscription.original_purchase.variant_attributes).to eq [@new_tier]
        expect(@subscription.original_purchase.offer_code_id).to eq offer_code.id
        expect(@subscription.original_purchase.displayed_price_cents).to eq 10_50
      end

      it "does not apply the offer code when downgrading tiers" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        select("Monthly", from: "Recurrence")

        choose @lower_tier.name

        expect(page).not_to have_text "You'll be charged"

        expect do
          click_on "Update membership"
          wait_for_ajax
          expect(page).to have_alert(text: "Your membership will be updated at the end of your current billing cycle.")
        end.to change { SubscriptionPlanChange.count }.from(0).to(1)

        plan_change = @subscription.subscription_plan_changes.first
        expect(plan_change.perceived_price_cents).to eq 2_50
      end

      it "does not error when not changing plans" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        click_on "Use a different card?"
        fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])
        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")
      end
    end

    context "and the offer code has changed since the subscription was purchased" do
      before do
        offer_code.update!(amount_cents: nil, amount_percentage: 10)
      end

      context "and the subscription has cached offer code details" do
        it "uses the old offer code attributes when updating" do
          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          choose "Second Tier"

          # shows the prorated price to be charged today
          expect(page).to have_text "You'll be charged US$5.87"

          click_on "Update membership"
          wait_for_ajax
          expect(page).to have_alert(text: "Your membership has been updated.")

          expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 5_87
          expect(@subscription.original_purchase.variant_attributes).to eq [@new_tier]
          expect(@subscription.original_purchase.offer_code_id).to eq offer_code.id

          new_discount = @subscription.original_purchase.purchase_offer_code_discount
          expect(new_discount).to be
          expect(new_discount.offer_code).to eq offer_code
          expect(new_discount.offer_code_amount).to eq 200
          expect(new_discount.offer_code_is_percent).to eq false
          expect(new_discount.pre_discount_minimum_price_cents).to eq @new_tier_quarterly_price.price_cents
        end
      end

      context "but the subscription does not have cached offer code details" do
        it "uses the new offer code attributes when updating" do
          @original_purchase.purchase_offer_code_discount.destroy!

          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          choose "Second Tier"

          # shows the prorated price to be charged today
          expect(page).to have_text "You'll be charged US$6.82"

          click_on "Update membership"
          wait_for_ajax
          expect(page).to have_alert(text: "Your membership has been updated.")

          expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 6_82
          expect(@subscription.original_purchase.variant_attributes).to eq [@new_tier]
          expect(@subscription.original_purchase.offer_code_id).to eq offer_code.id
          expect(@subscription.original_purchase.displayed_price_cents).to eq 9_45 # 10% off $10.50

          new_discount = @subscription.original_purchase.purchase_offer_code_discount
          expect(new_discount).to be
          expect(new_discount.offer_code).to eq offer_code
          expect(new_discount.offer_code_amount).to eq 10
          expect(new_discount.offer_code_is_percent).to eq true
          expect(new_discount.pre_discount_minimum_price_cents).to eq @new_tier_quarterly_price.price_cents
        end
      end
    end

    describe "100% off offer codes" do
      let(:offer_code) { create(:offer_code, amount_cents: nil, amount_percentage: 100) }

      before do
        @subscription.credit_card.destroy!
      end

      it "allows updating the membership without entering credit card details" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        expect(page).not_to have_content "Card Number"

        click_on "Update membership"
        wait_for_ajax
        expect(page).to have_alert(text: "Your membership has been updated.")
      end

      context "when the subscription has cached offer code details" do
        it "displays the price based on the cached pre-discount price and allows upgrading" do
          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          # shows the correct plan prices
          expect(page).to have_radio_button("First Tier", checked: true, text: "$5.99 $0")
          expect(page).to have_radio_button("Second Tier", text: "$10.50 $0")
          expect(page).to have_radio_button("Tier 3", text: "$4 $0")

          choose "Second Tier"
          expect(page).not_to have_text "You'll be charged" # does not show payment blurb since cost is $0 with offer code

          click_on "Update membership"
          wait_for_ajax
          expect(page).to have_alert(text: "Your membership has been updated.")

          new_original_purchase = @subscription.reload.original_purchase
          expect(new_original_purchase.variant_attributes).to eq [@new_tier]
          expect(new_original_purchase.offer_code_id).to eq offer_code.id

          new_discount = @subscription.original_purchase.purchase_offer_code_discount
          expect(new_discount).to be
          expect(new_discount.offer_code).to eq offer_code
          expect(new_discount.offer_code_amount).to eq 100
          expect(new_discount.offer_code_is_percent).to eq true
          expect(new_discount.pre_discount_minimum_price_cents).to eq @new_tier_quarterly_price.price_cents
        end
      end

      context "when the subscription does not have cached offer code details" do
        it "displays the price based on the current subscription price and allows upgrading" do
          @original_purchase.purchase_offer_code_discount.destroy!

          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          # shows the correct plan prices
          expect(page).to have_radio_button("First Tier", checked: true, text: "$0")
          expect(page).to have_radio_button("Second Tier", text: "$10.50 $0")
          expect(page).to have_radio_button("Tier 3", text: "$4 $0")

          choose "Second Tier"
          expect(page).not_to have_text "You'll be charged" # does not show payment blurb since cost is $0 with offer code

          click_on "Update membership"
          wait_for_ajax
          expect(page).to have_alert(text: "Your membership has been updated.")

          new_original_purchase = @subscription.reload.original_purchase
          expect(new_original_purchase.variant_attributes).to eq [@new_tier]
          expect(new_original_purchase.offer_code_id).to eq offer_code.id

          new_discount = @subscription.original_purchase.purchase_offer_code_discount
          expect(new_discount).to be
          expect(new_discount.offer_code).to eq offer_code
          expect(new_discount.offer_code_amount).to eq 100
          expect(new_discount.offer_code_is_percent).to eq true
          expect(new_discount.pre_discount_minimum_price_cents).to eq 10_50
        end
      end
    end
  end
end
