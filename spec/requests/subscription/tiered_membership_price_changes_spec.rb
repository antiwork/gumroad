# frozen_string_literal: true

require "spec_helper"

describe "Tiered Membership Price Changes Spec", type: :system, js: true do
  include ManageSubscriptionHelpers
  include ProductWantThisHelpers
  include CurrencyHelper

  before :each do
    setup_subscription
    travel_to(@originally_subscribed_at + 1.month)
    setup_subscription_token
  end

  context "changing tier" do
    context "to a more expensive tier" do
      it "upgrades the user" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Second Tier"

        # shows the prorated price to be charged today
        expect(page).to have_text "You'll be charged US$6.55"

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")
        expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 6_55
        expect(@subscription.original_purchase.variant_attributes).to eq [@new_tier]
      end

      it "creates a new mandate on Stripe if payment method requires a mandate" do
        indian_cc = create(:credit_card, user: @user, chargeable: create(:chargeable, card: StripePaymentMethodHelper.success_indian_card_mandate))
        @subscription.credit_card = indian_cc
        @subscription.save!

        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Second Tier"

        # shows the prorated price to be charged today
        expect(page).to have_text "You'll be charged US$6.55"

        click_on "Update membership"
        wait_for_ajax
        within_sca_frame do
          find_and_click("button:enabled", text: /COMPLETE/)
        end

        expect(page).to have_alert(text: "Your membership has been updated.")
        expect(@subscription.reload.purchases.successful.last.displayed_price_cents).to eq 6_55
        expect(@subscription.original_purchase.variant_attributes).to eq [@new_tier]

        expect(@subscription.reload.credit_card).to eq indian_cc
        expect(@subscription.credit_card.stripe_payment_intent_id).to be_present

        payment_intent = Stripe::PaymentIntent.retrieve(@subscription.credit_card.stripe_payment_intent_id)
        mandate_id = Stripe::Charge.retrieve(payment_intent.latest_charge).payment_method_details.card.mandate
        expect(Stripe::Mandate.retrieve(mandate_id)).to be_present
      end

      it "preserves existing tier and price if SCA fails for card requiring mandate" do
        indian_cc = create(:credit_card, user: @user, chargeable: create(:chargeable, card: StripePaymentMethodHelper.success_indian_card_mandate))
        @subscription.credit_card = indian_cc
        @subscription.save!

        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Second Tier"

        # shows the prorated price to be charged today
        expect(page).to have_text "You'll be charged US$6.55"

        click_on "Update membership"
        wait_for_ajax
        within_sca_frame do
          find_and_click("button:enabled", text: /FAIL/)
        end

        wait_for_ajax
        expect(page).not_to have_alert(text: "Your membership has been updated.")
        expect(@subscription.original_purchase.variant_attributes).to eq [@original_tier]
        expect(@subscription.reload.credit_card).to eq indian_cc
        expect(@subscription.credit_card.stripe_payment_intent_id).to be_present
      end
    end

    context "to a less expensive tier" do
      it "does not immediately upgrade the user" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Tier 3"

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership will be updated at the end of your current billing cycle.")
        expect(@subscription.reload.purchases.count).to eq 1
        expect(@subscription.subscription_plan_changes.count).to eq 1
        expect(@subscription.original_purchase.variant_attributes).to eq [@original_tier]
      end
    end

    context "to a different tier with the same price" do
      it "upgrades and charges the user" do
        @new_tier_quarterly_price.update!(price_cents: @original_tier_quarterly_price.price_cents)

        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Second Tier"

        # shows the prorated price to be charged today
        expect(page).to have_text "You'll be charged US$2.04"

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")
        expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 2_04
        expect(@subscription.original_purchase.variant_attributes).to eq [@new_tier]
      end
    end

    context "to the current tier" do
      it "makes no changes and does not charge the user" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Tier 3"
        choose "First Tier"

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")
        expect(@subscription.reload.purchases.count).to eq 1
      end
    end

    context "to a PWYW tier" do
      before :each do
        @new_tier.update!(customizable_price: true)
      end

      context "paying more than the current subscription" do
        it "does not let the user enter a price that is too low" do
          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          choose "Second Tier"
          fill_in "Name a fair price", placeholder: "10.50+", with: "10"
          click_on "Update membership"
          wait_for_ajax

          expect(page).to have_alert(text: "Please enter an amount greater than or equal to the minimum.")
        end

        it "allows the user to enter a valid price" do
          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          choose "Second Tier"
          fill_in "Name a fair price", with: "11"

          # shows the prorated price to be charged today
          expect(page).to have_text "You'll be charged US$7.05"

          click_on "Update membership"
          wait_for_ajax

          expect(page).to have_alert(text: "Your membership has been updated.")
          expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 7_05
          expect(@subscription.original_purchase.variant_attributes).to eq [@new_tier]
          expect(@subscription.original_purchase.displayed_price_cents).to eq 11_00
        end
      end

      context "paying less than the current subscription" do
        it "does not charge the user or upgrade them immediately" do
          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          choose "Second Tier"
          select("Monthly", from: "Recurrence")

          # shows prorated price if PWYW price is greater than current price
          pwyw_input = find_field "Name a fair price"
          pwyw_input.fill_in with: "11"
          expect(page).to have_text "You'll be charged US$7.05"

          # does not show price tag if PWYW price is less than current price
          pwyw_input.fill_in with: "5"
          expect(page).not_to have_text "You'll be charged"

          click_on "Update membership"
          wait_for_ajax

          expect(page).to have_alert(text: "Your membership will be updated at the end of your current billing cycle.")
          expect(@subscription.reload.purchases.count).to eq 1
          expect(@subscription.subscription_plan_changes.count).to eq 1
          expect(@subscription.recurrence).to eq "quarterly"
          expect(@subscription.original_purchase.displayed_price_cents).to eq 5_99
        end
      end
    end
  end

  context "changing payment option" do
    context "to a more expensive payment option" do
      it "upgrades the user" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        select("Every 2 years", from: "Recurrence")

        # shows the prorated price to be charged today
        expect(page).to have_text "You'll be charged US$14.05"

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")
        expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 14_05
        expect(@subscription.recurrence).to eq "every_two_years"
        expect(@subscription.original_purchase.displayed_price_cents).to eq 18_00
      end
    end

    context "to a less expensive payment option" do
      it "does not immediately upgrade the user" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        select("Monthly", from: "Recurrence")

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership will be updated at the end of your current billing cycle.")
        expect(@subscription.reload.purchases.count).to eq 1
        expect(@subscription.subscription_plan_changes.count).to eq 1
        expect(@subscription.recurrence).to eq "quarterly"
        expect(@subscription.original_purchase.displayed_price_cents).to eq 5_99
      end
    end
  end

  context "membership price has increased" do
    before :each do
      @original_tier_quarterly_price.update!(price_cents: 6_99)
    end

    it "displays the preexisting subscription price and does not charge the user on save" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      expect(page).not_to have_text "You'll be charged"
      expect(page).to have_radio_button("First Tier", checked: true, text: "$5.99")
      within find(:radio_button, text: "First Tier") do
        expect(page).to have_selector("[role='status']", text: "Your current plan is $5.99 every 3 months, based on previous pricing.")
      end

      click_on "Update membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Your membership has been updated.")
      expect(@subscription.reload.purchases.count).to eq 1
    end

    context "upgrading" do
      it "calculates the prorated amount based on the preexisting subscription price" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Second Tier"

        expect(page).to have_text "You'll be charged US$6.55"

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")
        expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 6_55
      end
    end
  end

  context "membership price has decreased" do
    before :each do
      @original_tier_quarterly_price.update!(price_cents: 4_99)
    end

    it "displays the preexisting subscription price and does not record a plan change for the user on save" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      expect(page).not_to have_text "You'll be charged"
      expect(page).to have_radio_button("First Tier", checked: true, text: "$5.99")
      within find(:radio_button, text: "First Tier") do
        expect(page).to have_selector("[role='status']", text: "Your current plan is $5.99 every 3 months, based on previous pricing.")
      end

      click_on "Update membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Your membership has been updated.")
      expect(@subscription.reload.purchases.count).to eq 1
      expect(@subscription.subscription_plan_changes.count).to eq 0
    end

    context "upgrading" do
      it "calculates the prorated amount based on the preexisting subscription price" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Second Tier"

        expect(page).to have_text "You'll be charged US$6.55"

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")
        expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 6_55
      end
    end
  end

  context "when current tier has been deleted" do
    before do
      @original_tier.mark_deleted!
    end

    it "can still select that tier" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      expect(page).to have_radio_button("First Tier", checked: true)

      choose "Second Tier"
      choose "First Tier"

      click_on "Update membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Your membership has been updated.")
      expect(@subscription.reload.purchases.count).to eq 1
    end

    it "cannot select different recurrences for that tier" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      expect(page).to have_radio_button("First Tier", checked: true)

      select("Yearly", from: "Recurrence")

      expect(page).to have_radio_button("First Tier", checked: true, disabled: true)
    end
  end

  context "when current payment option has been deleted" do
    before do
      @quarterly_product_price.mark_deleted!
      @original_tier_quarterly_price.mark_deleted!
      @new_tier_quarterly_price.mark_deleted!
      @lower_tier_quarterly_price.mark_deleted!
    end

    it "can still select that payment option" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      expect(page).to have_field("Recurrence", with: "quarterly")
      expect(page).to have_radio_button("First Tier", checked: true, text: "$5.99")

      select("Yearly", from: "Recurrence")
      select("Quarterly", from: "Recurrence")

      click_on "Update membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Your membership has been updated.")
      expect(@subscription.reload.purchases.count).to eq 1
    end

    it "cannot select deleted payment options for other tiers" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      expect(page).to have_radio_button(@new_tier.name, disabled: true)
      expect(page).to have_radio_button(@lower_tier.name, disabled: true)
      expect(page).to_not have_radio_button(@new_tier.name, disabled: false)
      expect(page).to_not have_radio_button(@lower_tier.name, disabled: false)

      select("Yearly", from: "Recurrence")

      expect(page).to_not have_radio_button(@new_tier.name, disabled: true)
      expect(page).to_not have_radio_button(@lower_tier.name, disabled: true)
      expect(page).to have_radio_button(@new_tier.name, disabled: false)
      expect(page).to have_radio_button(@lower_tier.name, disabled: false)
    end
  end

  context "changing seat count and/or billing frequency" do
    before do
      setup_subscription(quantity: 2)
      setup_subscription_token
    end

    context "when increasing the seat count" do
      it "does not display a warning notice regarding the seat change" do
        visit manage_subscription_path(@subscription.external_id, token: @subscription.token)

        fill_in "Seats", with: 3

        expect(page).to_not have_selector("[role='status']", text: "Changing the number of seats will update your subscription to the current price of")
      end
    end

    context "when increasing the billing frequency" do
      it "does not display a warning notice regarding the billing frequency" do
        visit manage_subscription_path(@subscription.external_id, token: @subscription.token)

        select("Monthly", from: "Recurrence")

        expect(page).to_not have_selector("[role='status']", text: "Changing the billing frequency will update your subscription to the current price of")
      end
    end

    context "when decreasing the seat count and decreasing the billing frequency" do
      it "does not display a warning notice regarding the seat and billing frequency change" do
        visit manage_subscription_path(@subscription.external_id, token: @subscription.token)

        select("Yearly", from: "Recurrence")
        fill_in "Seats", with: 1

        expect(page).to_not have_selector("[role='status']", text: "Changing the number of seats and adjusting the billing frequency will update your subscription to the current price of")
      end
    end

    context "when the price of the user's current tier has changed" do
      before do
        @subscription.original_purchase.variant_attributes.first.prices.find_by!(recurrence: "monthly").update!(price_cents: 3000)
        @subscription.original_purchase.variant_attributes.first.prices.find_by!(recurrence: "quarterly").update!(price_cents: 4000)
        @subscription.original_purchase.variant_attributes.first.prices.find_by!(recurrence: "yearly").update!(price_cents: 5000)
      end

      context "when decreasing the seat count" do
        it "displays a warning notice regarding the seat change" do
          visit manage_subscription_path(@subscription.external_id, token: @subscription.token)

          fill_in "Seats", with: 1

          expect(page).to have_selector("[role='status']", text: "Changing the number of seats will update your subscription to the current price of $40 every 3 months per seat.")
        end
      end

      context "when decreasing the billing frequency" do
        it "displays a warning notice regarding the billing frequency" do
          visit manage_subscription_path(@subscription.external_id, token: @subscription.token)

          select("Yearly", from: "Recurrence")

          expect(page).to have_selector("[role='status']", text: "Changing the billing frequency will update your subscription to the current price of $50 a year per seat.")
        end
      end

      context "when increasing the seat count and increasing the billing frequency" do
        it "displays a warning notice regarding the seat and billing frequency change" do
          visit manage_subscription_path(@subscription.external_id, token: @subscription.token)

          select("Monthly", from: "Recurrence")
          fill_in "Seats", with: 3

          expect(page).to have_selector("[role='status']", text: "Changing the number of seats and adjusting the billing frequency will update your subscription to the current price of $30 a month per seat.")
        end
      end
    end
  end

  context "when the subscription is overdue for charge" do
    before do
      @subscription.last_purchase.update(succeeded_at: 1.year.ago)
      @subscription.original_purchase.variant_attributes.first.prices.find_by!(recurrence: "quarterly").update!(price_cents: 5000)
    end

    it "charges the existing subscription price" do
      visit manage_subscription_path(@subscription.external_id, token: @subscription.token)
      within find(:radio_button, text: "First Tier") do
        expect(page).to_not have_selector("[role='status']", text: "Your current plan is $5.99 every 3 months, based on previous pricing.")
        expect(page).to have_text("$5.99 every 3 months")
      end

      click_on "Update membership"
      expect(page).to have_alert(text: "Your membership has been updated.")

      visit manage_subscription_path(@subscription.external_id, token: @subscription.token)
      within find(:radio_button, text: "First Tier") do
        expect(page).to have_selector("[role='status']", text: "Your current plan is $5.99 every 3 months, based on previous pricing.")
        expect(page).to have_text("$50 every 3 months")
      end
    end
  end
end
