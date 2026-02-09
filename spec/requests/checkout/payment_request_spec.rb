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
  end

  after(:each) do |example|
    if example.exception
      print_browser_logs
      puts "DEBUG: Failed Page Body: #{page.body.slice(0, 1000)}..."
    end
  end
end
