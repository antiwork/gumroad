# frozen_string_literal: true

require "spec_helper"

describe "Managing a membership saved on PayPal", type: :system, js: true do
  include ManageSubscriptionHelpers

  let(:gift) { nil }

  def paypal_account(visual: "paypal-buyer@example.com", processor: BraintreeChargeProcessor.charge_processor_id)
    card = create(:credit_card, chargeable: build(:native_paypal_chargeable))
    card.update!(visual:, charge_processor_id: processor, braintree_customer_id: "braintree-customer-id")
    card
  end

  def visit_manage_page
    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"
  end

  before do
    setup_subscription(gift:)
    travel_to(@originally_subscribed_at + 1.month)
  end

  context "when the membership renews on the buyer's PayPal account" do
    before do
      @paypal_account = paypal_account
      @subscription.update!(credit_card: @paypal_account)
      setup_subscription_token
    end

    it "opens on the saved PayPal account and keeps it when the buyer updates" do
      visit_manage_page

      expect(page).to have_radio_button("PayPal · paypal-buyer@example.com", checked: true)
      expect(page).not_to have_text("Your saved payment method is PayPal")

      expect do
        click_on "Update membership"
        expect(page).to have_alert(text: "Your membership has been updated.")
      end.not_to change { @subscription.purchases.count }

      expect(@subscription.reload.credit_card).to eq(@paypal_account)
      expect(page).to have_radio_button("PayPal · paypal-buyer@example.com", checked: true)
    end

    it "shows the card the membership renews on after switching away from PayPal" do
      visit_manage_page

      choose "Card"
      fill_in_credit_card(number: CardParamsSpecHelper.card_number(:success))
      click_on "Update membership"

      expect(page).to have_alert(text: "Your membership has been updated.")
      new_card = @subscription.reload.credit_card
      expect(new_card).not_to eq(@paypal_account)
      expect(page).to have_selector("[aria-label='Saved credit card']", text: ChargeableVisual.get_card_last4(new_card.visual))
      expect(page).not_to have_text("PayPal · paypal-buyer@example.com")
    end

    it "submits a move to a free tier from the saved PayPal lane" do
      @lower_tier_quarterly_price.update!(price_cents: 0)
      visit_manage_page

      choose @lower_tier.name
      expect(page).not_to have_radio_button("PayPal · paypal-buyer@example.com")
      click_on "Update membership"

      expect(page).to have_alert(text: /Your membership (will be|has been) updated/)
      expect(@subscription.reload.credit_card).to eq(@paypal_account)
    end

    it "keeps the saved PayPal label for a membership pending cancellation" do
      @subscription.update!(cancelled_at: @subscription.end_time_of_subscription, cancelled_by_buyer: true)
      visit_manage_page

      expect(page).to have_radio_button("PayPal · paypal-buyer@example.com", checked: true)
      expect(page).to have_button("Restart membership")
    end
  end

  context "when the seller can no longer charge the saved PayPal account" do
    before do
      @subscription.update!(credit_card: paypal_account(processor: PaypalChargeProcessor.charge_processor_id))
      setup_subscription_token
    end

    it "names the account and opens on the card fields" do
      visit_manage_page

      expect(page).to have_text("Your saved payment method is PayPal (paypal-buyer@example.com). It can't be used for this membership anymore, so choose a new payment method below.")
      expect(page).not_to have_radio_button("PayPal · paypal-buyer@example.com")
      expect(page).to have_selector("[aria-label='Card information']")
    end
  end

  context "when the membership is a gift" do
    let(:gift) { create(:gift, giftee_email: "giftee@example.com") }

    before do
      sender_paypal = paypal_account(visual: "gift-sender@example.com")
      @original_purchase.update!(credit_card: sender_paypal)
      @user.update!(credit_card: sender_paypal)
    end

    it "never shows the sender's PayPal account and asks the recipient for their own method" do
      setup_subscription_token
      visit_manage_page

      expect(page).to have_text("Add your own payment method below to ensure that your membership renews.")
      expect(page).not_to have_text("gift-sender@example.com")
    end

    it "shows the recipient's own PayPal account instead of asking for a payment method" do
      @subscription.update!(user: create(:user, credit_card: paypal_account(visual: "gift-recipient@example.com")))
      setup_subscription_token
      visit_manage_page

      expect(page).to have_radio_button("PayPal · gift-recipient@example.com", checked: true)
      expect(page).not_to have_text("Add your own payment method below")
      expect(page).not_to have_text("gift-sender@example.com")
    end
  end
end
