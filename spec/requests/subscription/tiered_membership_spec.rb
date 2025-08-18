# frozen_string_literal: true

require "spec_helper"

describe "Tiered Membership Spec", type: :system, js: true do
  include ManageSubscriptionHelpers
  include ProductWantThisHelpers
  include CurrencyHelper

  before :each do
    setup_subscription
    travel_to(@originally_subscribed_at + 1.month)
    setup_subscription_token
  end

  it "displays the currently selected tier, payment option, and card on file" do
    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    expect(page).to have_field("Recurrence", with: "quarterly")
    expect(page).to have_selector("[aria-label=\"Saved credit card\"]", text: ChargeableVisual.get_card_last4(@credit_card.visual))
    # initially hides payment blurb, as user owes nothing for current selection
    expect(page).not_to have_text "You'll be charged"

    expect(page).to have_radio_button("First Tier", checked: true, text: "$5.99")
  end

  it "displays the correct prices when toggling between options" do
    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    choose "Second Tier"
    wait_for_ajax
    expect(page).to have_text "You'll be charged US$6.55"

    choose "Tier 3"
    wait_for_ajax
    expect(page).not_to have_text "You'll be charged"

    choose "First Tier"
    wait_for_ajax
    expect(page).not_to have_text "You'll be charged"

    select("Yearly", from: "Recurrence")
    wait_for_ajax
    expect(page).to have_text "You'll be charged US$6.05"

    select("Monthly", from: "Recurrence")
    wait_for_ajax
    expect(page).not_to have_text "You'll be charged"
  end

  context "inactive membership" do
    before :each do
      travel_to(@originally_subscribed_at + 4.months)
      @subscription.update!(cancelled_at: 1.week.ago, deactivated_at: 1.week.ago, cancelled_by_buyer: true)
      setup_subscription_token
    end

    it "allows the user to restart their membership, and charges them" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      click_on "Restart membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Membership restarted")
      expect(@subscription.reload.purchases.successful.count).to eq 2
      expect(@subscription.cancelled_at).to be_nil
    end

    context "when the price has changed" do
      it "charges the pre-existing price" do
        old_price_cents = @original_tier_quarterly_price.price_cents
        @original_tier_quarterly_price.update!(price_cents: old_price_cents + 500)

        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        expect(page).to have_text "You'll be charged US$5.99"

        click_on "Restart membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Membership restarted")
        expect(@subscription.reload.purchases.successful.count).to eq 2
        expect(@subscription.purchases.last.displayed_price_cents).to eq old_price_cents
      end
    end

    context "when the discount is expired" do
      let!(:offer_code) { create(:offer_code, products: [@product], amount_cents: 100, code: "limited", duration_in_billing_cycles: 1) }

      it "charges the full price" do
        @subscription.original_purchase.update!(offer_code:, displayed_price_cents: 499, price_cents: 499)
        @subscription.original_purchase.create_purchase_offer_code_discount!(offer_code:, duration_in_billing_cycles: 1, pre_discount_minimum_price_cents: 599, offer_code_amount: 100)

        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        within find(:radio_button, text: "First Tier") do
          expect(page).to have_text("$5.99 every 3 months")
        end
        expect(page).to have_text("You'll be charged US$5.99")

        click_on "Restart membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Membership restarted")
        expect(@subscription.reload.purchases.successful.count).to eq 2
        expect(@subscription.purchases.last.displayed_price_cents).to eq 599
      end
    end
  end

  context "pending cancellation membership" do
    before do
      @subscription.update!(cancelled_at: @subscription.end_time_of_subscription, cancelled_by_buyer: true)
    end

    it "allows the user to restart their membership and does not charge them" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      expect(page).not_to have_text "You'll be charged"

      expect do
        click_on "Restart membership"
        wait_for_ajax
      end.not_to change { Purchase.count }

      expect(page).to have_alert(text: "Membership restarted")
      expect(@subscription.reload.cancelled_at).to be_nil
    end
  end

  context "overdue for charge but not inactive" do
    before do
      travel_back
    end

    it "allows the user to update their card and charges the new card" do
      travel_to(@originally_subscribed_at + 4.months)
      setup_subscription_token
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      expect(page).to have_text "You'll be charged US$5.99"

      click_on "Use a different card?"
      fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])
      click_on "Update membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Your membership has been updated.")
      expect(@subscription.reload.credit_card).not_to eq @credit_card
      expect(@subscription.credit_card).to be_present
      expect(@subscription.purchases.successful.count).to eq 2
    end

    it "correctly displays costs for different plans" do
      travel_to(@originally_subscribed_at + 4.months)
      setup_subscription_token
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      choose "Second Tier"
      wait_for_ajax
      expect(page).to have_text "You'll be charged US$10.50"

      choose "Tier 3"
      wait_for_ajax
      expect(page).to have_text "You'll be charged US$4"

      choose "First Tier"
      wait_for_ajax
      expect(page).to have_text "You'll be charged US$5.99"

      select("Yearly", from: "Recurrence")
      wait_for_ajax
      expect(page).to have_text "You'll be charged US$10"

      select("Monthly", from: "Recurrence")
      wait_for_ajax
      expect(page).to have_text "You'll be charged US$3"
    end

    context "for a monthly subscription begun in February" do
      it "displays the correct charge and updates successfully despite the 28 day billing period" do
        setup_subscription(originally_subscribed_at: Time.utc(2021, 02, 01), recurrence: "monthly")
        travel_to(Time.utc(2021, 03, 01))
        setup_subscription_token

        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        expect(page).to have_text "You'll be charged US$3"

        click_on "Use a different card?"
        fill_in_credit_card(number: CardParamsSpecHelper.success[:cc_number])
        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")
        expect(@subscription.reload.credit_card).not_to eq @credit_card
        expect(@subscription.credit_card).to be_present
        expect(@subscription.purchases.successful.count).to eq 2
      end
    end
  end

  context "test purchase" do
    it "creates a new test purchase when upgrading" do
      @product.update!(user: @user)
      @original_purchase.update!(seller: @user, purchase_state: "test_successful")
      @subscription.update!(is_test_subscription: true)

      login_as @user

      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      choose "Second Tier"

      expect(page).to have_text "You'll be charged US$6.55"

      click_on "Update membership"

      expect(page).to have_selector("h1", text: "Library")

      upgrade_purchase = @subscription.reload.purchases.last
      expect(upgrade_purchase.purchase_state).to eq "test_successful"
      expect(upgrade_purchase.displayed_price_cents).to eq 6_55
      expect(@subscription.original_purchase.variant_attributes).to eq [@new_tier]
    end
  end

  context "upgrade charge is less than product price minimum" do
    before do
      travel_back
    end

    it "rounds up to the minimum" do
      @new_tier_quarterly_price.update!(price_cents: 6_25)

      travel_to(@originally_subscribed_at + 1.hour) do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        choose "Second Tier"

        expect(page).to have_text "You'll be charged US$0.99"

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")
        expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 99
        expect(@subscription.original_purchase.displayed_price_cents).to eq 6_25
      end
    end

    context "when updating a PWYW price" do
      it "rounds up to the minimum" do
        setup_subscription(pwyw: true)
        setup_subscription_token
        expect(@original_purchase.displayed_price_cents).to eq 6_99

        travel_to(@originally_subscribed_at + 1.hour) do
          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          pwyw_input = find_field "Name a fair price"
          pwyw_input.fill_in with: ""
          pwyw_input.fill_in with: "7.50"
          wait_for_ajax

          expect(page).to have_text "You'll be charged US$0.99"

          click_on "Update membership"
          wait_for_ajax

          expect(page).to have_alert(text: "Your membership has been updated.")
          expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 99
          expect(@subscription.original_purchase.displayed_price_cents).to eq 7_50
        end
      end
    end

    context "when changing to a PWYW tier" do
      it "rounds up to the minimum" do
        @new_tier.update!(customizable_price: true)
        @new_tier_quarterly_price.update!(price_cents: 6_09) # $0.10 more than existing plan

        travel_to(@originally_subscribed_at + 1.hour) do
          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          choose "Second Tier"

          pwyw_input = find_field("Name a fair price")
          pwyw_input.fill_in with: "6.50"
          wait_for_ajax

          expect(page).to have_text "You'll be charged US$0.99"

          click_on "Update membership"
          wait_for_ajax

          expect(page).to have_alert(text: "Your membership has been updated.")
          expect(@subscription.reload.purchases.last.displayed_price_cents).to eq 99
          expect(@subscription.original_purchase.displayed_price_cents).to eq 6_50
        end
      end
    end

    context "for non-USD currency" do
      it "rounds up to the minimum product price for that currency" do
        currency = "cad"
        change_membership_product_currency_to(@product, currency)
        set_tier_price_difference_below_min_upgrade_price(currency)
        displayed_upgrade_charge_in_usd = formatted_price("usd", get_usd_cents(currency, @min_price_in_currency))

        travel_to(@originally_subscribed_at + 1.hour) do
          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          choose "Second Tier"

          expect(page).to have_text "You'll be charged US#{displayed_upgrade_charge_in_usd}"

          click_on "Update membership"
          wait_for_ajax

          expect(page).to have_alert(text: "Your membership has been updated.")
          expect(@subscription.reload.purchases.last.displayed_price_cents).to eq @min_price_in_currency
          expect(@subscription.original_purchase.displayed_price_cents).to eq @new_price
        end
      end
    end
  end
end
