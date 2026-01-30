# frozen_string_literal: true

require "spec_helper"

describe "Refund Funding Settings", type: :system, js: true do
  let(:seller) { create(:user, name: "Test Seller") }

  before do
    create(:user_compliance_info, user: seller)
    login_as seller
  end

  describe "banner on Customers page" do
    it "shows the refund payment method banner when no card is configured" do
      visit customers_path

      expect(page).to have_text("Refund customers instantly")
      expect(page).to have_link("Set up backup method")
    end

    it "hides the banner when dismissed" do
      visit customers_path

      expect(page).to have_text("Refund customers instantly")
      click_button "close"

      expect(page).not_to have_text("Refund customers instantly")

      # Banner stays hidden on refresh
      visit customers_path
      expect(page).not_to have_text("Refund customers instantly")
    end

    it "does not show banner when seller has a backup card configured" do
      credit_card = create(:credit_card)
      seller.update!(refund_funding_credit_card: credit_card)

      visit customers_path

      expect(page).not_to have_text("Refund customers instantly")
    end
  end

  describe "Settings > Payments page" do
    it "shows the refund payment method section" do
      visit settings_payments_path

      expect(page).to have_text("Refund payment method")
      expect(page).to have_text("Add a credit card to automatically cover refunds")
    end

    it "shows saved card details when configured" do
      credit_card = create(:credit_card, visual: "**** 4242", card_type: "visa", card_holder_name: "John Doe")
      seller.update!(refund_funding_credit_card: credit_card)

      visit settings_payments_path

      expect(page).to have_text("**** 4242")
      expect(page).to have_text("John Doe")
      expect(page).to have_button("Remove")
    end

    context "with Stripe mocked", :vcr do
      it "allows adding a backup payment method" do
        visit settings_payments_path

        within_section "Refund payment method" do
          click_on "Add refund payment method"
        end

        fill_in "Name on card", with: "Test User"

        # Fill Stripe card element (using Stripe test token in test env)
        within_frame(find("iframe[name*='__privateStripeFrame']")) do
          fill_in "cardnumber", with: "4242424242424242"
          fill_in "exp-date", with: "1230"
          fill_in "cvc", with: "123"
        end

        click_button "Save"

        expect(page).to have_alert(text: "Refund payment method saved successfully!")
        expect(page).to have_text("**** 4242")
      end
    end

    it "allows removing the backup payment method" do
      credit_card = create(:credit_card, visual: "**** 4242", card_holder_name: "John Doe")
      seller.update!(refund_funding_credit_card: credit_card)

      visit settings_payments_path

      within_section "Refund payment method" do
        click_button "Remove"
      end

      # Confirm removal
      click_button "Confirm" if page.has_button?("Confirm")

      expect(page).not_to have_text("**** 4242")
      expect(page).to have_text("Add a credit card to automatically cover refunds")
    end
  end

  # Integration tests with the refund flow require VCR cassettes and full
  # browser rendering. They are tested via controller and service specs instead.
end
