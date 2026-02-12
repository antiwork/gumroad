# frozen_string_literal: true

require "spec_helper"

describe "Checkout with Google Pay", :js, type: :system do
  let(:product) { create(:product, price_cents: 2000, name: "Test Product") }

  before do
    mock_payment_request_availability(apple_pay: false, google_pay: true)
  end

  after do
    clear_payment_request_mocks
  end

  context "when Google Pay is available" do
    it "allows selecting Google Pay" do
      visit product.long_url
      add_to_cart(product)

      expect(page).to have_field("Google Pay", type: "radio", wait: 10)

      within_fieldset("Payment method") do
        expect(page).to have_text("Google Pay")

        google_pay_label = find("label", text: "Google Pay")
        expect(google_pay_label).to have_selector("svg, img, [class*='google'], [class*='GooglePay']")
      end

      choose "Google Pay"

      expect(page).to have_checked_field("Google Pay", wait: 5)
      expect(page).not_to have_field("Card number")
      expect(page).not_to have_field("MM / YY")
      expect(page).not_to have_field("CVC")
      expect(page).to have_button("Pay", wait: 5)
    end

    it "can switch between Google Pay and credit card" do
      visit product.long_url
      add_to_cart(product)

      choose "Google Pay"
      expect(page).not_to have_field("Card number")

      choose "Credit card"
      expect(page).to have_field("Card number", wait: 5)
      expect(page).to have_field("MM / YY")
      expect(page).to have_field("CVC")

      choose "Google Pay"
      expect(page).not_to have_field("Card number")
    end

    it "returns to input state when payment is cancelled" do
      visit product.long_url
      add_to_cart(product)

      fill_in "Email address", with: "buyer@example.com"

      choose "Google Pay"

      click_button "Pay"

      expect(page).to have_button("Pay", wait: 10)
      expect(page).to have_checked_field("Google Pay")
    end

    it "requires email before allowing payment" do
      visit product.long_url
      add_to_cart(product)

      choose "Google Pay"

      expect(page).to have_button("Pay", disabled: true, wait: 5)
      expect(page).to have_field("Email address")

      fill_in "Email address", with: "buyer@example.com"

      expect(page).to have_button("Pay", disabled: false, wait: 5)
    end
  end

  context "when Google Pay is not available" do
    before do
      clear_payment_request_mocks
      mock_payment_request_availability(apple_pay: false, google_pay: false)
    end

    it "does not show Google Pay option" do
      visit product.long_url
      add_to_cart(product)

      expect(page).not_to have_field("Google Pay", type: "radio")

      expect(page).to have_field("Credit card", type: "radio", wait: 10)
    end

    it "allows credit card checkout as fallback" do
      visit product.long_url
      add_to_cart(product)

      expect(page).to have_checked_field("Credit card", wait: 10)

      expect(page).to have_field("Card number")
      expect(page).to have_field("MM / YY")
      expect(page).to have_field("CVC")
    end
  end

  context "with physical products" do
    let(:physical_product) { create(:product, :physical, price_cents: 3000) }

    before do
      mock_payment_request_availability(apple_pay: false, google_pay: true)
    end

    it "shows Google Pay option for physical products" do
      visit physical_product.long_url
      add_to_cart(physical_product)

      expect(page).to have_field("Google Pay", type: "radio", wait: 10)
    end

    it "collects shipping address when using Google Pay" do
      visit physical_product.long_url
      add_to_cart(physical_product)

      choose "Google Pay"

      expect(page).to have_button("Pay", wait: 5)
    end
  end

  context "with recurring products" do
    let(:subscription_product) { create(:product, :membership, price_cents: 1500, recurrence: "monthly") }

    before do
      mock_payment_request_availability(apple_pay: false, google_pay: true)
    end

    it "shows Google Pay option for subscriptions" do
      visit subscription_product.long_url
      add_to_cart(subscription_product)

      expect(page).to have_field("Google Pay", type: "radio", wait: 10)
    end

    it "has payment button available for subscriptions" do
      visit subscription_product.long_url
      add_to_cart(subscription_product)

      choose "Google Pay"

      expect(page).to have_button(text: /Pay|Subscribe/, wait: 5)
    end
  end

  context "when both Apple Pay and Google Pay are available" do
    before do
      clear_payment_request_mocks
      mock_payment_request_availability(apple_pay: true, google_pay: true)
    end

    it "shows both payment options" do
      visit product.long_url
      add_to_cart(product)

      expect(page).to have_field("Apple Pay", type: "radio", wait: 10)
      expect(page).to have_field("Google Pay", type: "radio")
    end

    it "can switch between both express payment methods" do
      visit product.long_url
      add_to_cart(product)

      choose "Google Pay"
      expect(page).to have_checked_field("Google Pay")
      expect(page).not_to have_field("Card number")

      choose "Apple Pay"
      expect(page).to have_checked_field("Apple Pay")
      expect(page).not_to have_field("Card number")

      choose "Credit card"
      expect(page).to have_checked_field("Credit card")
      expect(page).to have_field("Card number", wait: 5)
    end
  end
end
