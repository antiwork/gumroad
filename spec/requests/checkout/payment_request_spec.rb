# frozen_string_literal: true

require "spec_helper"

describe "Checkout with Payment Request (Apple Pay / Google Pay)", :js, type: :system do
  include PaymentRequestMockHelper

  before do
    allow_any_instance_of(User).to receive(:profile_url).and_return("#{PROTOCOL}://#{DOMAIN}")
    @product = create(:product, price_cents: 1000, name: "Digital Product")
    @seller = @product.user
    # Ensure Stripe is enabled for the seller - using stripe_connect to avoid long verification delays
    create(:merchant_account_stripe_connect, user: @seller)
  end

  context "when Apple Pay is supported" do
    before do
      mock_payment_request(supports_apple_pay: true, supports_google_pay: false)
    end

    it "shows the Apple Pay button" do
      visit @product.long_url
      add_to_cart(@product)

      # Verify the express checkout button for Apple Pay is present
      expect(page).to have_selector(".brand-icon-apple")
      expect(page).to have_text("Apple Pay")
    end

    it "allows selecting Apple Pay as payment method" do
      visit @product.long_url
      add_to_cart(@product)

      # Select Apple Pay
      find("h4", text: "Apple Pay").click

      # Verify Apple Pay is selected
      expect(find("[role='tab']", text: "Apple Pay")["aria-selected"]).to eq("true")
      expect(page).to have_button("Pay")
    end

    it "hides credit card fields when Apple Pay is selected" do
      visit @product.long_url
      add_to_cart(@product)

      # Initially card is default
      expect(page).to have_text("Card information")

      # Select Apple Pay
      find("h4", text: "Apple Pay").click

      # Verify Apple Pay is selected before checking fields (ensures state update)
      expect(find("[role='tab']", text: "Apple Pay")["aria-selected"]).to eq("true")

      # Card fields should be hidden
      expect(page).to have_no_text("Card information")
      expect(page).to have_no_text("Name on card")
    end

    it "returns to input state when Apple Pay payment is cancelled" do
      visit @product.long_url
      add_to_cart(@product)

      fill_in "Email address", with: "test@gumroad.com"

      # Select Apple Pay
      find("h4", text: "Apple Pay").click

      # Trigger cancel mock
      page.execute_script("window.__triggerPaymentCancel = true;")

      # Click Pay
      click_on "Pay", exact: true

      # Should return to form
      expect(page).to have_field("Email address", with: "test@gumroad.com")
      expect(page).to have_button("Pay")
    end

    it "enters processing state when Pay is clicked with Apple Pay" do
      visit @product.long_url
      add_to_cart(@product)

      fill_in "Email address", with: "test@gumroad.com"

      # Select Apple Pay
      find("h4", text: "Apple Pay").click
      expect(find("[role='tab']", text: "Apple Pay")["aria-selected"]).to eq("true")

      # Click Pay - should trigger the payment request show()
      click_on "Pay", exact: true

      # The page should enter a processing/loading state
      expect(page).to have_text("Processing")
    end
  end

  context "when Google Pay is supported" do
    before do
      mock_payment_request(supports_apple_pay: false, supports_google_pay: true)
    end

    it "shows the Google Pay button" do
      visit @product.long_url
      add_to_cart(@product)

      expect(page).to have_selector(".brand-icon-google")
      expect(page).to have_text("Google Pay")
    end

    it "allows selecting Google Pay as payment method" do
      visit @product.long_url
      add_to_cart(@product)

      find("h4", text: "Google Pay").click

      expect(find("[role='tab']", text: "Google Pay")["aria-selected"]).to eq("true")

      # Verify Google Pay is selected
      expect(find("[role='tab']", text: "Google Pay")["aria-selected"]).to eq("true")
      expect(page).to have_button("Pay")
    end
  end

  context "when both are supported" do
    before do
      mock_payment_request(supports_apple_pay: true, supports_google_pay: true)
    end

    it "prioritizes Google Pay (per implementation logic)" do
      visit @product.long_url
      add_to_cart(@product)

      # In PaymentForm.tsx: {paymentMethods.googlePay ? "Google Pay" : "Apple Pay"}
      expect(page).to have_text("Google Pay")
    end

    it "can switch between Payment Request and credit card" do
      visit @product.long_url
      add_to_cart(@product)

      # Switch to Payment Request (Google Pay is prioritized in mock when both supported)
      find("h4", text: "Google Pay").click
      expect(find("[role='tab']", text: "Google Pay")["aria-selected"]).to eq("true")
      expect(page).to have_no_text("Card information")
      expect(page).to have_no_text("Name on card")

      # Switch back to Card
      find("h4", text: "Card").click
      expect(find("[role='tab']", text: "Card")["aria-selected"]).to eq("true")
      expect(page).to have_text("Card information")
      expect(page).to have_text("Name on card")
    end
  end

  context "with physical product requiring shipping" do
    before do
      @physical_product = create(:product, price_cents: 1000, name: "Physical Product", require_shipping: true)
      mock_payment_request(supports_apple_pay: true, supports_google_pay: false)
    end

    it "shows shipping fields and Apple Pay for physical products" do
      visit @physical_product.long_url
      add_to_cart(@physical_product)

      # Initial price is $10.00
      expect(page).to have_text("US$10")

      # Should show shipping fields for physical product
      expect(page).to have_text("Shipping information")
      expect(page).to have_field("Full name")
      expect(page).to have_field("Street address")

      # Apple Pay should still be available
      expect(page).to have_text("Apple Pay")
      find("h4", text: "Apple Pay").click
      expect(find("[role='tab']", text: "Apple Pay")["aria-selected"]).to eq("true")
    end
  end

  after(:each) do |example|
    if example.exception
      print_browser_logs
      puts "DEBUG: Failed Page Body: #{page.body.slice(0, 1000)}..."
    end
  end
end
