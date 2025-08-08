# frozen_string_literal: true

require "spec_helper"

describe "Installment plan receipt", type: :feature, js: true do
  let(:first_purchase) { create(:installment_plan_purchase) }
  let(:subscription) { first_purchase.subscription }
  let(:product) { first_purchase.link }
  let(:manage_subscription_url) { Rails.application.routes.url_helpers.manage_subscription_url(subscription.external_id, host: "#{PROTOCOL}://#{DOMAIN}") }

  before do
    create(:url_redirect, purchase: first_purchase)

    allow(GlobalConfig).to receive(:dig)
      .with(:secure_external_id, default: {})
      .and_return({
                    primary_key_version: "1",
                    keys: { "1" => "a" * 32 }
                  })
  end

  it "shows updated messaging and installment counters; shows final payment note on last receipt" do
    visit receipt_purchase_url(first_purchase.external_id, host: "#{PROTOCOL}://#{DOMAIN}")
    expect(page).to have_content("Confirm your email address")
    fill_in "Email address:", with: first_purchase.email
    click_button "View receipt"

    expect(page).to have_text("Today's payment: 1 of 3")
    expect(page).to have_text("Upcoming payment: 2 of 3")
    expect(page).to have_text("Installment plan initiated on", normalize_ws: true)
    expect(page).to have_text("Your final charge will be on", normalize_ws: true)
    expect(page).to have_link("here", href: manage_subscription_url)

    second_purchase = create(:recurring_installment_plan_purchase,
                           subscription: subscription,
                           link: product,
                           created_at: 1.month.from_now)

    visit receipt_purchase_url(second_purchase.external_id, host: "#{PROTOCOL}://#{DOMAIN}")
    expect(page).to have_content("Confirm your email address")
    fill_in "Email address:", with: second_purchase.email
    click_button "View receipt"

    expect(page).to have_text("Today's payment: 2 of 3")
    expect(page).to have_text("Upcoming payment: 3 of 3")

    third_purchase = create(:recurring_installment_plan_purchase,
                          subscription: subscription,
                          link: product,
                          created_at: 2.months.from_now)

    visit receipt_purchase_url(third_purchase.external_id, host: "#{PROTOCOL}://#{DOMAIN}")
    expect(page).to have_content("Confirm your email address")
    fill_in "Email address:", with: third_purchase.email
    click_button "View receipt"

    expect(page).to have_text("This is your final payment for your installment plan. You will not be charged again")
    expect(page).to have_text("Total paid", normalize_ws: true)
  end
end
