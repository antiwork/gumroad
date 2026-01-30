# frozen_string_literal: true

require "spec_helper"

describe "Checkout subscription restart", :js, :sidekiq_inline, type: :system do
  let(:seller) { create(:user) }
  let(:membership_product) { create(:membership_product, user: seller, price_cents: 1000) }
  let(:buyer) { create(:user, email: "buyer@example.com") }

  def create_subscription_for_product(product:, purchaser:, email:, **subscription_attrs)
    subscription = create(:subscription, link: product, user: purchaser)
    create(:purchase,
           link: product,
           purchaser: purchaser,
           email: email,
           subscription: subscription,
           is_original_subscription_purchase: true,
           price_cents: product.prices.alive.first.price_cents,
           variant_attributes: product.tiers.to_a
    )
    subscription.update!(subscription_attrs) if subscription_attrs.present?
    subscription
  end

  def checkout_url_for(product)
    tier = product.tiers.first
    "/checkout?product=#{product.unique_permalink}&option=#{tier.external_id}"
  end

  def complete_checkout(with_email: nil)
    fill_in "Email address", with: with_email if with_email.present?
    fill_in_credit_card
    fill_in "ZIP code", with: "94107"
    click_button "Pay"
    expect(page).to have_text("Your purchase was successful", wait: 30)
  end

  describe "when user has an active subscription" do
    let!(:existing_subscription) do
      create_subscription_for_product(
        product: membership_product,
        purchaser: buyer,
        email: buyer.email
      )
    end

    context "when signed in" do
      before do
        login_as buyer
      end

      it "shows helpful error message about existing subscription" do
        visit checkout_url_for(membership_product)
        fill_checkout_form(membership_product, email: nil, logged_in_user: buyer)
        click_button "Pay"

        expect(page).to have_alert(text: "You already have an active subscription to this membership. Visit your Library to manage it.")
      end
    end

    context "when signed out" do
      it "shows generic error message (privacy)" do
        visit checkout_url_for(membership_product)
        fill_checkout_form(membership_product, email: buyer.email, logged_in_user: nil)
        click_button "Pay"

        expect(page).to have_alert(text: "Sorry, something went wrong. Please try again.")
        expect(page).not_to have_text("subscription")
      end
    end
  end

  describe "when user has a cancelled subscription" do
    let!(:cancelled_subscription) do
      create_subscription_for_product(
        product: membership_product,
        purchaser: buyer,
        email: buyer.email,
        cancelled_at: 1.day.ago,
        cancelled_by_buyer: true,
        deactivated_at: 1.day.ago
      )
    end

    context "when signed in" do
      before do
        login_as buyer
      end

      it "transparently restarts the subscription and shows success" do
        visit checkout_url_for(membership_product)
        complete_checkout

        cancelled_subscription.reload
        expect(cancelled_subscription.cancelled_at).to be_nil
        expect(cancelled_subscription.deactivated_at).to be_nil
      end
    end

    context "when signed out with matching email" do
      it "transparently restarts the subscription" do
        visit checkout_url_for(membership_product)
        complete_checkout(with_email: buyer.email)

        cancelled_subscription.reload
        expect(cancelled_subscription.cancelled_at).to be_nil
      end
    end
  end

  describe "when user has a failed subscription" do
    let!(:failed_subscription) do
      create_subscription_for_product(
        product: membership_product,
        purchaser: buyer,
        email: buyer.email,
        failed_at: 1.day.ago,
        deactivated_at: 1.day.ago
      )
    end

    context "when signed in" do
      before do
        login_as buyer
      end

      it "transparently restarts the subscription" do
        visit checkout_url_for(membership_product)
        complete_checkout

        failed_subscription.reload
        expect(failed_subscription.failed_at).to be_nil
        expect(failed_subscription.deactivated_at).to be_nil
      end
    end
  end

  describe "when subscription was cancelled by seller" do
    let!(:seller_cancelled_subscription) do
      create_subscription_for_product(
        product: membership_product,
        purchaser: buyer,
        email: buyer.email,
        cancelled_at: 1.day.ago,
        cancelled_by_buyer: false,
        cancelled_by_admin: true,
        deactivated_at: 1.day.ago
      )
    end

    context "when signed in" do
      before do
        login_as buyer
      end

      it "creates a new subscription instead of restarting" do
        visit checkout_url_for(membership_product)

        expect do
          complete_checkout
        end.to change { Subscription.count }.by(1)
      end
    end
  end

  describe "gift purchases" do
    let!(:giftee_cancelled_subscription) do
      giftee = create(:user, email: "giftee@example.com")
      create_subscription_for_product(
        product: membership_product,
        purchaser: giftee,
        email: "giftee@example.com",
        cancelled_at: 1.day.ago,
        cancelled_by_buyer: true,
        deactivated_at: 1.day.ago
      )
    end

    context "when signed in" do
      before do
        login_as buyer
      end

      it "creates a new subscription for giftee instead of restarting their cancelled one" do
        visit checkout_url_for(membership_product)

        check_out(membership_product, gift: { email: "giftee@example.com" }, logged_in_user: buyer)

        giftee_cancelled_subscription.reload
        expect(giftee_cancelled_subscription.cancelled_at).to be_present
      end
    end
  end
end
