# frozen_string_literal: true

require "spec_helper"

# Throwaway spec for PR #5880 receipt screenshots — DO NOT COMMIT.
describe("Receipt gift screenshots", type: :system, js: true) do
  let(:tag) { ENV["SHOT_TAG"] || "shot" }

  before do
    @product = create(:product, name: "Monthly Model File")
  end

  def resize(w, h)
    page.driver.browser.manage.window.resize_to(w, h)
  rescue StandardError
    nil
  end

  def buy_as_gift
    visit @product.long_url
    add_to_cart(@product)
    fill_checkout_form(@product, email: "test@gumroad.com", gift: { email: "friend@gumroad.com", note: "Enjoy!" })
    click_on "Pay", exact: true
    expect(page).to have_text("Your purchase was successful!", wait: 60)
    sleep 1
  end

  it "captures the success receipt card (desktop)" do
    buy_as_gift
    resize(1280, 1400)
    sleep 1
    page.save_screenshot("/tmp/receipt-shots/#{tag}-receipt-desktop.png")
  end

  it "captures the success receipt card (mobile)", :mobile_view do
    buy_as_gift
    page.save_screenshot("/tmp/receipt-shots/#{tag}-receipt-mobile.png")
  end
end
