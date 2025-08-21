# frozen_string_literal: true

require "spec_helper"

describe "Tiered Membership VAT Spec", type: :system, js: true do
  include ManageSubscriptionHelpers
  include ProductWantThisHelpers
  before :each do
    setup_subscription
    travel_to(@originally_subscribed_at + 1.month)
    setup_subscription_token
    Capybara.current_session.driver.browser.manage.delete_all_cookies

    create(:zip_tax_rate, country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)
    create(:zip_tax_rate, country: "FR", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false)
    allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("2.47.255.255") # Italy
  end

  context "when original purchase was not charged VAT" do
    it "does not charge VAT even if has EU IP address" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"
      choose "Second Tier"

      # does not show VAT
      expect(page).to have_text "You'll be charged US$6.55"
      expect(page).not_to have_selector(".payment-blurb .js-tax-amount")

      click_on "Update membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Your membership has been updated.")

      # updated original purchase has correct tax info
      updated_purchase = @subscription.reload.original_purchase
      expect(updated_purchase.gumroad_tax_cents).to eq 0
      expect(updated_purchase.total_transaction_cents).to eq 10_50
      expect(updated_purchase.purchase_sales_tax_info.ip_country_code).to be_nil
      expect(updated_purchase.purchase_sales_tax_info.ip_address).not_to eq "2.47.255.255"

      # upgrade purchase has correct tax info
      last_purchase = @subscription.purchases.last
      expect(last_purchase.displayed_price_cents).to eq 6_55
      expect(last_purchase.total_transaction_cents).to eq 6_55
      expect(last_purchase.gumroad_tax_cents).to eq 0
      expect(last_purchase.purchase_sales_tax_info.ip_country_code).to be_nil
      expect(last_purchase.purchase_sales_tax_info.ip_address).not_to eq "2.47.255.255"
    end
  end

  context "when the original purchase was charged VAT" do
    it "uses the original purchase's country and VAT" do
      travel_back
      setup_subscription_with_vat
      travel_to(@originally_subscribed_at + 1.month)
      setup_subscription_token

      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"
      choose "Second Tier"

      # shows the prorated price to be charged today, including VAT
      expect(page).to have_text "You'll be charged US$7.86 today, including US$1.31 for VAT in France"

      click_on "Update membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Your membership has been updated.")

      # updated original purchase has correct taxes - $10.50 * 0.20 = $2.10
      updated_purchase = @subscription.reload.original_purchase
      expect(updated_purchase.gumroad_tax_cents).to eq 2_10
      expect(updated_purchase.total_transaction_cents).to eq 12_60
      expect(updated_purchase.purchase_sales_tax_info.country_code).to eq "FR"
      expect(updated_purchase.purchase_sales_tax_info.ip_address).to eq "2.16.255.255"

      # upgrade purchase has correct taxes - $6.55 * 0.20 = $1.31
      last_purchase = @subscription.purchases.last
      expect(last_purchase.displayed_price_cents).to eq 6_55
      expect(last_purchase.total_transaction_cents).to eq 7_86
      expect(last_purchase.gumroad_tax_cents).to eq 1_31
      expect(last_purchase.purchase_sales_tax_info.country_code).to eq "FR"
      expect(last_purchase.purchase_sales_tax_info.ip_address).to eq "2.16.255.255"
    end
  end

  context "when the original purchase had a VAT ID set" do
    it "uses the same VAT ID for the new subscription" do
      allow_any_instance_of(VatValidationService).to receive(:process).and_return(true)
      travel_back
      setup_subscription_with_vat(vat_id: "FR123456789")
      travel_to(@originally_subscribed_at + 1.month)
      setup_subscription_token

      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"
      choose "Second Tier"

      expect(page).to have_text "You'll be charged US$6.55"

      click_on "Update membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Your membership has been updated.")

      # updated original purchase has correct taxes
      updated_purchase = @subscription.reload.original_purchase
      expect(updated_purchase.gumroad_tax_cents).to eq 0
      expect(updated_purchase.total_transaction_cents).to eq 10_50
      expect(updated_purchase.purchase_sales_tax_info.business_vat_id).to eq "FR123456789"

      # upgrade purchase has correct taxes - $6.55 * 0.20 = $1.31
      last_purchase = @subscription.purchases.last
      expect(last_purchase.gumroad_tax_cents).to eq 0
      expect(last_purchase.total_transaction_cents).to eq 6_55
      expect(last_purchase.purchase_sales_tax_info.business_vat_id).to eq "FR123456789"
    end
  end
end
