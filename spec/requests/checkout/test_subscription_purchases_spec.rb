# frozen_string_literal: true

require "spec_helper"

describe "Test subscription purchases", :js, type: :system do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, is_recurring_billing: true, subscription_duration: :monthly, price_cents: 500) }

  it "allows the seller to create multiple test purchases for a membership product" do
    login_as seller
    visit product.long_url
    add_to_cart(product)
    fill_in "ZIP code", with: "12345"
    click_on "Pay"
    expect(page).to have_alert(text: "Your purchase was successful!")

    first_subscription = product.subscriptions.last
    expect(first_subscription).to be_present
    expect(first_subscription).to be_is_test_subscription

    first_subscription.update!(
      cancelled_at: Time.current,
      cancelled_by_buyer: true,
      deactivated_at: Time.current
    )

    visit product.long_url
    add_to_cart(product)
    fill_in "ZIP code", with: "12345"
    click_on "Pay"
    expect(page).to have_alert(text: "Your purchase was successful!")

    expect(product.subscriptions.reload.count).to eq(2)
    second_subscription = product.subscriptions.order(:created_at).last
    expect(second_subscription).to be_is_test_subscription
    expect(second_subscription.id).not_to eq(first_subscription.id)
  end

  it "does not block the seller when they have an active test subscription" do
    existing_subscription = create(:subscription, link: product, user: seller, is_test_subscription: true)
    create(:purchase,
           is_original_subscription_purchase: true,
           link: product,
           subscription: existing_subscription,
           purchaser: seller,
           seller: seller,
           email: seller.email,
           purchase_state: "test_successful",
           price_cents: product.price_cents,
           variant_attributes: product.tiers.to_a)

    login_as seller
    visit product.long_url
    add_to_cart(product)
    fill_in "ZIP code", with: "12345"
    click_on "Pay"

    expect(page).to have_alert(text: "Your purchase was successful!", wait: 45)
    expect(product.subscriptions.reload.count).to eq(2)
  end
end
