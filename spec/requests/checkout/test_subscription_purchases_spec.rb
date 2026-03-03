# frozen_string_literal: true

require "spec_helper"

describe "Test subscription purchases", :js, type: :system do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, is_recurring_billing: true, subscription_duration: :monthly, price_cents: 500) }

  it "allows the seller to create multiple test purchases for a membership product" do
    # First test purchase
    login_as seller
    visit product.long_url
    add_to_cart(product)
    fill_in "ZIP code", with: "12345"
    click_on "Pay"
    expect(page).to have_alert(text: "Your purchase was successful!")

    first_subscription = product.subscriptions.last
    expect(first_subscription).to be_present
    expect(first_subscription).to be_is_test_subscription

    # Cancel the first test subscription to simulate the scenario
    first_subscription.update!(
      cancelled_at: Time.current,
      cancelled_by_buyer: true,
      deactivated_at: Time.current
    )

    # Second test purchase - this should succeed without being blocked
    visit product.long_url
    add_to_cart(product)
    fill_in "ZIP code", with: "12345"
    click_on "Pay"
    expect(page).to have_alert(text: "Your purchase was successful!")

    # Should have created a new subscription, not restarted the old one
    expect(product.subscriptions.reload.count).to eq(2)
    second_subscription = product.subscriptions.order(:created_at).last
    expect(second_subscription).to be_is_test_subscription
    expect(second_subscription.id).not_to eq(first_subscription.id)
  end

  it "does not block the seller when they have an active test subscription" do
    # Create an existing active test subscription
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

    # Try to create another test purchase - this should succeed
    login_as seller
    visit product.long_url
    add_to_cart(product)
    fill_in "ZIP code", with: "12345"
    click_on "Pay"

    # The purchase should succeed since test subscriptions should not block new test purchases
    expect(page).to have_alert(text: "Your purchase was successful!")
    expect(product.subscriptions.reload.count).to eq(2)
  end
end
