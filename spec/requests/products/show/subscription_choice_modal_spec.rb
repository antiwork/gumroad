# frozen_string_literal: true

require "spec_helper"

describe "Subscription choice modal on product page", :js, type: :system do
  let(:seller) { create(:named_user) }
  let(:product) { create(:membership_product, user: seller, price_cents: 500) }
  let(:tier) { product.default_tier }
  let(:buyer) { create(:user) }

  def create_subscription_with_purchase(state: :active)
    credit_card = create(:credit_card, user: buyer)
    subscription = create(:subscription, link: product, user: buyer, credit_card: credit_card)
    travel_to(5.minutes.ago) do
      create(:purchase,
             is_original_subscription_purchase: true,
             link: product,
             subscription: subscription,
             purchaser: buyer,
             email: buyer.email,
             credit_card: credit_card,
             variant_attributes: [tier],
             price_cents: product.price_cents)
    end

    if state == :lapsed
      subscription.update!(cancelled_at: 1.day.ago, deactivated_at: 1.day.ago, cancelled_by_buyer: true)
    end

    subscription
  end

  context "when logged-in buyer has an active subscription" do
    before do
      create_subscription_with_purchase
      login_as buyer
    end

    it "shows modal with start new subscription option" do
      visit short_link_path(product)

      click_on "Purchase again"

      expect(page).to have_text("You already have an active subscription")
      expect(page).to have_link("Start a new subscription")
      expect(page).not_to have_link("Resume subscription")
    end

    it "navigates to checkout with force_new_subscription when starting new subscription" do
      visit short_link_path(product)

      click_on "Purchase again"
      click_on "Start a new subscription"

      expect(page).to have_current_path(%r{/checkout})
    end
  end

  context "when logged-in buyer has a lapsed subscription" do
    before do
      create_subscription_with_purchase(state: :lapsed)
      login_as buyer
    end

    it "shows modal with both resume and start new subscription options" do
      visit short_link_path(product)

      click_on "Purchase again"

      expect(page).to have_text("Resume your previous subscription?")
      expect(page).to have_link("Resume subscription")
      expect(page).to have_link("Start a new subscription")
    end
  end

  context "when buyer is logged out" do
    it "does not show the modal and navigates directly to checkout" do
      visit short_link_path(product)

      click_on "Subscribe"

      expect(page).not_to have_text("Resume your previous subscription?")
      expect(page).to have_current_path(%r{/checkout})
    end
  end
end
