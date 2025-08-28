# frozen_string_literal: true

require "spec_helper"

describe "Missing Tiered Membership Spec", type: :system, js: true do
  include ManageSubscriptionHelpers
  include ProductWantThisHelpers
  include CurrencyHelper

  before :each do
    setup_subscription
    travel_to(@originally_subscribed_at + 1.month)
    setup_subscription_token
    @original_purchase.update!(variant_attributes: [])
  end

  it "allows the user to update their subscription" do
    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    expect(page).to have_field("Recurrence", with: "quarterly")
    expect(page).to have_selector("[aria-label=\"Saved credit card\"]", text: ChargeableVisual.get_card_last4(@credit_card.visual))
    # initially hides payment blurb, as user owes nothing for current selection
    expect(page).not_to have_text "You'll be charged"

    expect(page).to have_radio_button("First Tier", checked: true, text: "$5.99")

    fill_in "Email", with: "edgarg@gumroad.com"

    click_on "Update membership"
    wait_for_ajax

    expect(page).to have_alert(text: "Your membership has been updated.")
    expect(@original_purchase.reload.email).to eq "edgarg@gumroad.com"
  end

  it "allows the user to upgrade their plan" do
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

  it "allows the user to downgrade their plan" do
    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    choose "Tier 3"

    click_on "Update membership"
    wait_for_ajax

    expect(page).to have_alert(text: "Your membership will be updated at the end of your current billing cycle.")
    expect(@subscription.reload.purchases.count).to eq 1
    expect(@subscription.subscription_plan_changes.count).to eq 1
    expect(@subscription.original_purchase.variant_attributes).to eq [@original_tier]
  end

  context "and membership price has changed" do
    before :each do
      @original_tier_quarterly_price.update!(price_cents: 6_99)
    end

    it "displays the preexisting subscription price and does not charge the user on save" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      expect(page).not_to have_text "You'll be charged"
      expect(page).to have_radio_button("First Tier", checked: true, text: "$5.99")

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
end
