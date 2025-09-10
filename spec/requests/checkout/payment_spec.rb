# frozen_string_literal: true

require "spec_helper"

describe "Checkout payment", :js, type: :system do
  before do
    @product = create(:product, price_cents: 1000)
    Feature.deactivate(:disable_braintree_sales)
  end

  it "shows native, braintree, or no paypal button depending on availability" do
    create(:merchant_account_paypal, user: @product.user, charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")
    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    select_tab "PayPal"
    expect(page).to have_selector("iframe[title=PayPal]")

    product2 = create(:product, price_cents: 1000)
    visit "/l/#{product2.unique_permalink}"
    add_to_cart(product2)
    select_tab "PayPal"
    expect(page).to_not have_selector("iframe[title=PayPal]")
    expect(page).to have_button "Pay"

    product3 = create(:product, price_cents: 1000)
    product3.user.update!(disable_paypal_sales: true)
    visit "/l/#{product3.unique_permalink}"
    add_to_cart(product3)
    expect(page).to_not have_tab_button "PayPal"
  end

  context "email typo suggestions" do
    before { Feature.activate(:require_email_typo_acknowledgment) }

    it "disables the payment button until typo suggestion is resolved" do
      visit @product.long_url
      add_to_cart(@product)

      expect(page).to have_button "Pay", disabled: false

      fill_in "Email address", with: "hi@gnail.com"
      unfocus
      expect(page).to have_text "Did you mean hi@gmail.com?"
      expect(page).to have_button "Pay", disabled: true

      # Rejecting the typo suggestion does NOT update the field value.
      within_fieldset "Email address" do
        click_on "No"
      end
      expect(page).to have_field("Email address", with: "hi@gnail.com")
      expect(page).to have_button "Pay", disabled: false

      fill_in "Email address", with: "hi@hotnail.com"
      unfocus
      expect(page).to have_text "Did you mean hi@hotmail.com?"
      expect(page).to have_button "Pay", disabled: true

      # Accepting the typo suggestion updates the field value.
      within_fieldset "Email address" do
        click_on "Yes"
      end
      expect(page).to have_field("Email address", with: "hi@hotmail.com")
      expect(page).to have_button "Pay", disabled: false

      # Re-entering a typo that has been acknowledged should not show
      # suggestions again.
      fill_in "Email address", with: "hi@gnail.com"
      unfocus
      expect(page).to_not have_text "Did you mean"
      expect(page).to have_button "Pay", disabled: false
    end

    context "feature flag is off" do
      before { Feature.deactivate(:require_email_typo_acknowledgment) }

      it "does not block the payment button" do
        visit @product.long_url
        add_to_cart(@product)

        expect(page).to have_button "Pay", disabled: false

        fill_in "Email address", with: "hi@gnail.com"
        unfocus
        expect(page).to have_text "Did you mean hi@gmail.com?"
        expect(page).to have_button "Pay", disabled: false
      end
    end
  end
end
