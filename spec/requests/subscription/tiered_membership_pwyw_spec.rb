# frozen_string_literal: true

require "spec_helper"

describe "Tiered Membership Spec for a PWYW tier", type: :system, js: true do
  include ManageSubscriptionHelpers
  include ProductWantThisHelpers
  include CurrencyHelper

  before :each do
    setup_subscription
    travel_to(@originally_subscribed_at + 1.month)
    setup_subscription_token
  end

  it "displays the price the user is currently paying" do
    @original_tier.update!(customizable_price: true)
    @original_purchase.update!(displayed_price_cents: 7_50)

    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    expect(page).to have_field("Name a fair price", with: "7.50")

    # shows the correct price in the label
    expect(page).to have_radio_button("First Tier", checked: true, text: "$5.99+")
  end

  it "displays the correct prices when toggling between options" do
    # PWYW tier already selected
    @original_tier.update!(customizable_price: true)

    # PWYW tier
    @new_tier.update!(customizable_price: true)
    @new_tier.prices.find_by(recurrence: BasePrice::Recurrence::QUARTERLY).update!(price_cents: 5_00, suggested_price_cents: 6_50) # with suggested price set
    @new_tier.prices.find_by(recurrence: BasePrice::Recurrence::MONTHLY).update!(price_cents: 1_50, suggested_price_cents: nil) # without suggested price set

    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    choose "Second Tier"
    expect(page).to have_field("Name a fair price", with: nil) # just shows placeholder
    fill_in "Name a fair price", with: "11.50"
    wait_for_ajax
    expect(page).to have_text "You'll be charged US$7.55" # prorated_discount_price_cents

    select("Monthly", from: "Recurrence")
    expect(page).to have_field("Name a fair price", with: nil) # clears the entered price
    select("Quarterly", from: "Recurrence")

    choose "Tier 3"
    wait_for_ajax
    expect(page).not_to have_text "You'll be charged"

    choose "First Tier"
    wait_for_ajax
    expect(page).to have_field("Name a fair price", with: "5.99") # shows existing price you're paying
    expect(page).not_to have_text "You'll be charged"
  end

  it "displays the correct price owed when changing PWYW price" do
    @original_tier.update!(customizable_price: true)
    @original_purchase.update!(displayed_price_cents: 7_50)

    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    pwyw_input = find_field("Name a fair price")
    pwyw_input.fill_in with: "" # Sometimes the next value isn't filled in correctly without this
    pwyw_input.fill_in with: "10"
    wait_for_ajax
    expect(page).to have_text "You'll be charged US$5.05"

    pwyw_input.fill_in with: ""
    pwyw_input.fill_in with: "5"
    wait_for_ajax
    expect(page).not_to have_text "You'll be charged"
  end
end
