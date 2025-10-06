# frozen_string_literal: true

require "spec_helper"

describe "Installment Plans", type: :system, js: true do
  include ManageSubscriptionHelpers

  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:credit_card) { create(:credit_card) }

  let(:product) { create(:product, :with_installment_plan, user: seller, price_cents: 30_00) }

  RSpec.shared_context "setup installment plan subscription" do |started_at: Time.current|
    let(:subscription) { create(:subscription, is_installment_plan: true, credit_card:, user: buyer, link: product) }
    let(:purchase) { create(:installment_plan_purchase, subscription:, link: product, credit_card:, purchaser: buyer) }

    before do
      travel_to(started_at) do
        subscription
        purchase
      end

      setup_subscription_token(subscription:)
    end
  end

  context "paid in full" do
    include_context "setup installment plan subscription"

    it "404s when the installment plan has been paid in full (ended_at set)" do
      subscription.end_subscription!

      visit manage_subscription_path(subscription.external_id, token: subscription.token)

      expect(page).to have_text("Not Found")
    end

    it "404s when all charges are completed even without ended_at being set" do
      # Create all required purchases to complete the installment plan
      product.installment_plan.number_of_installments.times do |i|
        next if i.zero? # Skip first one as it's already created in setup

        create(:recurring_installment_plan_purchase,
               subscription: subscription,
               link: product,
               credit_card: credit_card,
               purchaser: buyer)
      end

      # Verify charges_completed? returns true
      expect(subscription.reload.charges_completed?).to be true
      # Verify ended_at is NOT set (this is the vulnerability condition)
      expect(subscription.ended_at).to be_nil

      # This should 404 even though ended_at is not set
      visit manage_subscription_path(subscription.external_id, token: subscription.token)

      expect(page).to have_text("Not Found")
    end

    it "prevents restarting a completed installment plan via API" do
      # Complete all installments
      product.installment_plan.number_of_installments.times do |i|
        next if i.zero?

        create(:recurring_installment_plan_purchase,
               subscription: subscription,
               link: product,
               credit_card: credit_card,
               purchaser: buyer)
      end

      expect(subscription.reload.charges_completed?).to be true

      # Attempt to restart via UpdaterService
      updater = Subscription::UpdaterService.new(
        subscription: subscription,
        params: {
          contact_info: { email: buyer.email },
          use_existing_card: true
        },
        logged_in_user: buyer,
        gumroad_guid: SecureRandom.uuid,
        remote_ip: "127.0.0.1"
      )

      result = updater.perform

      expect(result[:success]).to be false
      expect(result[:error_message]).to eq("This installment plan has been paid in full and cannot be restarted.")
    end
  end

  context "active with overdue charges" do
    include_context "setup installment plan subscription", started_at: 33.days.ago

    it "allows updating the installment plan's credit card and charges the new card" do
      visit manage_subscription_path(subscription.external_id, token: subscription.token)

      click_on "Use a different card?"

      fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])
      expect(page).to have_text "You'll be charged US$10 today."

      expect do
        click_on "Update installment plan"
        wait_for_ajax

        expect(page).to have_alert(text: "Your installment plan has been updated")
      end
        .to change { subscription.purchases.successful.count }.by(1)
        .and change { subscription.reload.credit_card }.from(credit_card).to(be_present)
    end
  end

  context "active with no overdue charges" do
    include_context "setup installment plan subscription"

    it "displays the payment method that'll be used for future charges" do
      visit manage_subscription_path(subscription.external_id, token: subscription.token)
      expect(page).to have_selector("[aria-label=\"Saved credit card\"]", text: /#{ChargeableVisual.get_card_last4(credit_card.visual)}$/)
    end

    it "allows updating the installment plan's credit card" do
      visit manage_subscription_path(subscription.external_id, token: subscription.token)

      click_on "Use a different card?"

      fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])

      expect do
        click_on "Update installment plan"
        wait_for_ajax

        expect(page).to have_alert(text: "Your installment plan has been updated.")
      end
        .to change { subscription.purchases.successful.count }.by(0)
        .and change { subscription.reload.credit_card }.from(credit_card).to(be_present)
    end

    it "does not allow cancelling" do
      visit manage_subscription_path(subscription.external_id, token: subscription.token)

      expect(page).not_to have_button("Cancel")
    end
  end

  context "failed" do
    include_context "setup installment plan subscription", started_at: 40.days.ago

    before { subscription.unsubscribe_and_fail! }

    it "allows updating the installment plan's credit card and charges the new card" do
      visit manage_subscription_path(subscription.external_id, token: subscription.token)

      click_on "Use a different card?"

      fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])
      expect(page).to have_text "You'll be charged US$10 today."

      expect do
        click_on "Restart installment plan"
        wait_for_ajax

        expect(page).to have_alert(text: "Installment plan restarted")
      end
        .to change { subscription.purchases.successful.count }.by(1)
        .and change { subscription.reload.credit_card }.from(credit_card).to(be_present)
    end
  end
end
