# frozen_string_literal: true

require "spec_helper"

describe "Tiered Memberships Fixed Length Spec", type: :system, js: true do
  include ManageSubscriptionHelpers

  before :each do
    setup_subscription
    @subscription.update!(charge_occurrence_count: 4)
    travel_to(@originally_subscribed_at + 1.month)
    setup_subscription_token
  end

  it "allows the user to update the credit card" do
    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    click_on "Use a different card?"
    fill_in_credit_card(number: CardParamsSpecHelper.success[:cc_number])

    click_on "Update membership"

    expect(page).to have_alert(text: "Your membership has been updated.")

    @subscription.reload
    @user.reload
    expect(@subscription.credit_card).to be
    expect(@subscription.credit_card).not_to eq @credit_card
    expect(@user.credit_card).to be
    expect(@user.credit_card).to eq @credit_card
  end

  it "allows the user to set their name, email, and address when applicable" do
    @product.update!(require_shipping: true)
    @original_purchase.update!(full_name: "Jim Gumroad", street_address: "805 St Cloud Road",
                               city: "Los Angeles", state: "CA", zip_code: "11111",
                               country: "United States")

    buyer_email = generate(:email)

    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    fill_in "Email", with: buyer_email
    fill_in "Full name", with: "Jane Gumroad"
    fill_in "Street address", with: "100 Main St"
    fill_in "City", with: "San Francisco"
    select "CA", from: "State"
    fill_in "ZIP code", with: "00000"
    select "United States", from: "Country"

    click_on "Update membership"
    click_on "Yes, it is"
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

  it "does not allow the user to change tier" do
    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    choose "Second Tier"

    # shows the prorated price to be charged today
    expect(page).to have_text "You'll be charged US$6.55"

    click_on "Update membership"
    wait_for_ajax

    expect(page).to have_alert(text: "Changing plans for fixed-length subscriptions is not currently supported.")
  end

  it "does not allow the user to change recurrence" do
    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    select("Yearly", from: "Recurrence")

    # shows the prorated price to be charged today
    expect(page).to have_text "You'll be charged US$6.05"

    click_on "Update membership"
    wait_for_ajax

    expect(page).to have_alert(text: "Changing plans for fixed-length subscriptions is not currently supported.")
  end
end
