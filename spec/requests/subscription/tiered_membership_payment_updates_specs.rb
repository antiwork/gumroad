# frozen_string_literal: true

require "spec_helper"

describe "Tiered Membership Spec for Payment/Settings updates", type: :system, js: true do
  include ManageSubscriptionHelpers
  include ProductWantThisHelpers
  include CurrencyHelper

  let(:gift) { null }

  before do
    setup_subscription(gift:)
    travel_to(@originally_subscribed_at + 1.month)
    setup_subscription_token
  end

  context "updating card on file" do
    it "triggers the reCAPTCHA verification" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      click_on "Use a different card?"
      fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])

      click_on "Update membership"

      # Assert that the reCAPTCHA iframe is rendered
      expect(page).to have_selector("#payButtonRecaptcha iframe")
      expect(page).to have_alert(text: "Your membership has been updated.")
    end

    context "with a valid card" do
      it "updates the card" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        expect(page).to_not have_text("Your first charge will be on")
        expect(page).to_not have_text("Your membership is paid up until")
        expect(page).to_not have_text("Add your own payment method below to ensure that your membership renews.")

        click_on "Use a different card?"
        fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])

        click_on "Update membership"

        expect(page).to have_alert(text: "Your membership has been updated.")

        @subscription.reload
        @user.reload
        expect(@subscription.credit_card).to be
        expect(@subscription.credit_card).not_to eq @credit_card
        expect(@user.credit_card).to be
        expect(@user.credit_card).not_to eq @credit_card
      end

      context "when the price has changed" do
        before do
          @original_tier_quarterly_price.update!(price_cents: 1000)
        end

        it "updates the card without changing the price" do
          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          click_on "Use a different card?"
          fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])

          click_on "Update membership"
          expect(page).to have_alert(text: "Your membership has been updated.")
          expect(@subscription.reload.current_plan_displayed_price_cents).to eq(599)
        end
      end

      context "when the price has changed and is now 0" do
        before do
          @original_tier_quarterly_price.update!(price_cents: 0)
        end

        it "still allows updating the card" do
          visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

          click_on "Use a different card?"
          fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])

          click_on "Update membership"
          expect(page).to have_alert(text: "Your membership has been updated.")
          expect(@subscription.reload.current_plan_displayed_price_cents).to eq(599)
        end
      end
    end

    context "with an invalid card" do
      it "does not update the card and returns an error message" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        click_on "Use a different card?"
        fill_in_credit_card(number: StripePaymentMethodHelper.decline[:cc_number])

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Please check your card information, we couldn't verify it.")

        @subscription.reload
        @user.reload
        expect(@subscription.credit_card).to be
        expect(@subscription.credit_card).to eq @credit_card
        expect(@user.credit_card).to be
        expect(@user.credit_card).to eq @credit_card
      end
    end

    context "for a test subscription" do
      it "does not let the user update the card when signed in" do
        @subscription.update!(is_test_subscription: true)

        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        expect(page).to have_selector(".test_card")
        expect(page).not_to have_selector(".use_different_card")
      end
    end
  end

  context "switching from PayPal to credit card" do
    it "allows switching even if the creator does not have pay with PayPal enabled" do
      allow_any_instance_of(User).to receive(:pay_with_paypal_enabled?).and_return(false)

      paypal_card = create(:credit_card, chargeable: build(:paypal_chargeable))
      @subscription.update!(credit_card: paypal_card)
      @subscription.user.update!(credit_card: paypal_card)

      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      click_on "Pay with card instead?"
      fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])
      click_on "Update membership"

      expect(page).to have_alert(text: "Your membership has been updated.")

      @subscription.reload
      @user.reload
      expect(@subscription.credit_card).to be
      expect(@subscription.credit_card).not_to eq paypal_card
      expect(@user.credit_card).to be
      expect(@user.credit_card).not_to eq paypal_card
    end
  end

  context "setting additional information" do
    context "when the product requires shipping info" do
      before :each do
        @product.update!(require_shipping: true)

        @original_purchase.update!(full_name: "Jim Gumroad", street_address: "805 St Cloud Road",
                                   city: "Los Angeles", state: "CA", zip_code: "11111",
                                   country: "United States")
      end

      it "allows the user to set their name, email, and address" do
        buyer_email = generate(:email)

        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        fill_in "Email", with: buyer_email
        fill_in "Full name", with: "Jane Gumroad"
        fill_in "Street address", with: "100 Main St"
        fill_in "City", with: "San Francisco"
        select "CA", from: "state"
        fill_in "ZIP code", with: "00000"
        select "United States", from: "country"

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")

        @original_purchase.reload
        expect(@original_purchase.email).to eq buyer_email
        expect(@original_purchase.full_name).to eq "Jane Gumroad"
        expect(@original_purchase.street_address).to eq "100 Main St"
        expect(@original_purchase.city).to eq "San Francisco"
        expect(@original_purchase.state).to eq "CA"
        expect(@original_purchase.zip_code).to eq "00000"
        expect(@original_purchase.country).to eq "United States"
      end

      it "requires address to be present" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        fill_in "Full name", with: ""
        click_on "Update membership"
        wait_for_ajax
        expect(page).to have_alert(text: "Full name can't be blank")
        fill_in "Full name", with: @original_purchase.full_name

        fill_in "Street address", with: ""
        click_on "Update membership"
        wait_for_ajax
        expect(page).to have_alert(text: "Street address can't be blank")
        fill_in "Street address", with: @original_purchase.street_address

        fill_in "City", with: ""
        click_on "Update membership"
        wait_for_ajax
        expect(page).to have_alert(text: "City can't be blank")
        fill_in "City", with: @original_purchase.city

        fill_in "ZIP code", with: ""
        click_on "Update membership"
        wait_for_ajax
        expect(page).to have_alert(text: "Zip code can't be blank")
      end
    end

    context "when the product does not require shipping info" do
      it "only allows the user to set their email" do
        new_email = generate(:email)

        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        expect(page).not_to have_field("Full name")
        expect(page).not_to have_field("Street address")
        expect(page).not_to have_field("City")
        expect(page).not_to have_field("State")
        expect(page).not_to have_field("State Select")
        expect(page).not_to have_field("Country")
        expect(page).not_to have_field("ZIP code")

        fill_in "Email", with: new_email

        click_on "Update membership"
        wait_for_ajax

        expect(page).to have_alert(text: "Your membership has been updated.")

        @original_purchase.reload
        expect(@original_purchase.email).to eq new_email
      end
    end

    it "requires email to be present" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      fill_in "Email", with: ""

      click_on "Update membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Validation failed: valid email required")
    end
  end

  context "coming from a declined charge email and charge fails again" do
    it "does not enqueue declined card tasks" do
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_raise ChargeProcessorCardError, "unknown error"

      expect(CustomerLowPriorityMailer).to_not receive(:subscription_card_declined)

      visit "/subscriptions/#{@subscription.external_id}/manage?declined=true"

      click_on "Second Tier"
      click_on "Update membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Please check your card information, we couldn't verify it.")
    end
  end

  it "allows updating the membership's credit card to an Indian card which requires SCA and mandate" do
    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    click_on "Use a different card?"

    fill_in_credit_card(number: StripePaymentMethodHelper.success_indian_card_mandate[:cc_number])
    click_on "Update membership"
    wait_for_ajax
    sleep 1
    within_sca_frame do
      find_and_click("button:enabled", text: /COMPLETE/)
    end

    expect(page).to have_alert(text: "Your membership has been updated.")
    expect(@subscription.reload.credit_card).not_to eq @credit_card
    expect(@subscription.credit_card).to be
    expect(@subscription.credit_card.stripe_setup_intent_id).to be_present
    expect(Stripe::SetupIntent.retrieve(@subscription.credit_card.stripe_setup_intent_id).mandate).to be_present
  end

  context "giftee using the manage membership" do
    let(:gift) { create(:gift, giftee_email: "giftee@gumroad.com") }

    it "displays a notice about the card, updates the card on file, and upgrades membership" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      expect(page).to have_text("Your membership is paid up until")
      expect(page).to have_text("Add your own payment method below to ensure that your membership renews.")
      expect(find_field("Email").value).to eq @subscription.email

      expect(@subscription.credit_card).to be_nil

      fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])

      click_on "Update membership"
      expect(page).to have_alert(text: "Your membership has been updated.")
      @subscription.reload
      expect(@subscription.credit_card).to be_present

      travel_to(@subscription.end_time_of_subscription + 1.day)
      @subscription.charge!

      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      choose "Second Tier"
      click_on "Update membership"
      expect(page).to have_button("Update membership", disabled: false)
      expect(page).to have_alert(text: "Your membership has been updated.")

      @subscription.reload
      expect(@subscription.gift?).to be true

      expect(@subscription.true_original_purchase).to have_attributes(
        is_gift_sender_purchase: true,
        price_cents: 599
      )

      expect(@subscription.original_purchase).to have_attributes(
        is_gift_sender_purchase: false,
        price_cents: 1050
      )
    end
  end
end
