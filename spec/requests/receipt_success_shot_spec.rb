# frozen_string_literal: true

require "spec_helper"

# Throwaway spec for PR #5880 receipt screenshots — DO NOT COMMIT.
describe("Receipt success screenshots", type: :system, js: true) do
  let(:tag) { ENV["SHOT_TAG"] || "shot" }

  before do
    @product1 = create(:product, name: "Monthly Model File")
    @product2 = create(:product_with_digital_versions, name: "Texture Pack Vol. 2")
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
    add_to_cart(@product2, option: "Untitled 1")
    check_out(@product2)

    expect(page).to have_text("Create an account to access all of your purchases", wait: 60)
    resize(1280, 1400)
    sleep 1
    page.save_screenshot("/tmp/receipt-shots/#{tag}-success-desktop.png")
  end

  it "captures the success receipt with signup form (mobile)", :mobile_view do
    visit @product1.long_url
    add_to_cart(@product1)
    visit @product2.long_url
    add_to_cart(@product2, option: "Untitled 1")
    check_out(@product2)

    expect(page).to have_text("Create an account to access all of your purchases", wait: 60)
    sleep 1
    page.save_screenshot("/tmp/receipt-shots/#{tag}-success-mobile.png")
  end
end
