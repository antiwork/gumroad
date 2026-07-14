# frozen_string_literal: true

require "spec_helper"

# Throwaway spec for PR #5880 receipt screenshots — DO NOT COMMIT.
describe("Receipt screenshots", type: :system, js: true) do
  let(:tag) { ENV["SHOT_TAG"] || "shot" }

  before do
    @seller = create(:named_user)
    @product1 = create(:product, name: "Monthly Model File", user: @seller, price_cents: 500)
    @product2 = create(:product, name: "Texture Pack Vol. 2", user: @seller, price_cents: 900)
  end

  def resize(w, h)
    page.driver.browser.manage.window.resize_to(w, h)
  rescue StandardError
    nil
  end

  it "captures the success receipt with signup form (desktop)" do
    visit @product1.long_url
    add_to_cart(@product1)
    visit @product2.long_url
    add_to_cart(@product2)
    fill_checkout_form(@product2, email: "test@gumroad.com")
    click_on "Pay", exact: true
    expect(page).to have_text("Create an account to access all of your purchases", wait: 60)
    resize(1280, 1400)
    sleep 1
    page.save_screenshot("/tmp/receipt-shots/#{tag}-success-desktop.png")
  end

  it "captures the success receipt with signup form (mobile)", :mobile_view do
    visit @product1.long_url
    add_to_cart(@product1)
    visit @product2.long_url
    add_to_cart(@product2)
    fill_checkout_form(@product2, email: "test@gumroad.com")
    click_on "Pay", exact: true
    expect(page).to have_text("Create an account to access all of your purchases", wait: 60)
    sleep 1
    page.save_screenshot("/tmp/receipt-shots/#{tag}-success-mobile.png")
  end

  it "captures the receipt with a failed line item (desktop)" do
    visit @product1.long_url
    add_to_cart(@product1)
    visit @product2.long_url
    add_to_cart(@product2)
    fill_checkout_form(@product2, email: "test@gumroad.com")
    @product2.update!(price_cents: 10_000)
    click_on "Pay", exact: true
    expect(page).to have_text("Summary", wait: 60)
    resize(1280, 1400)
    sleep 1
    page.save_screenshot("/tmp/receipt-shots/#{tag}-failed-desktop.png")
  end
end
