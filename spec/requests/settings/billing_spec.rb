# frozen_string_literal: true

require "spec_helper"

describe("Billing Settings Scenario", type: :system, js: true) do
  let(:buyer) { create(:user, name: "Alice") }

  before { login_as buyer }

  describe "saving billing details" do
    it "lets a buyer enter and save their legal business billing details" do
      visit settings_billing_path

      fill_in "Full name", with: "Alice GmbH"
      fill_in "Business name (optional)", with: "Acme GmbH"
      fill_in "Street address", with: "1 Unter den Linden"
      fill_in "City", with: "Berlin"
      fill_in "ZIP code", with: "10115"
      select "Germany", from: "Country"
      fill_in "VAT ID (optional)", with: "DE123456789"

      click_on "Update settings"

      expect(page).to have_text("Your billing details have been saved")

      billing_detail = buyer.reload.billing_detail
      expect(billing_detail).to be_present
      expect(billing_detail.business_name).to eq("Acme GmbH")
      expect(billing_detail.business_id).to eq("DE123456789")
      expect(billing_detail.country_code).to eq("DE")
    end

    it "hides the State field when the selected country is not the US" do
      visit settings_billing_path
      select "Germany", from: "Country"
      expect(page).not_to have_field("State")

      select "United States", from: "Country"
      expect(page).to have_field("State")
    end

    it "updates the business ID label when the country changes" do
      visit settings_billing_path
      select "Germany", from: "Country"
      expect(page).to have_field("VAT ID (optional)")

      select "Brazil", from: "Country"
      expect(page).to have_field("CNPJ (optional)")
    end
  end

  describe "invoice page pre-fill" do
    let!(:billing_detail) do
      create(
        :billing_detail,
        purchaser: buyer,
        full_name: "Alice GmbH",
        business_name: "Acme GmbH",
        business_id: "DE123456789",
        street_address: "1 Unter den Linden",
        city: "Berlin",
        zip_code: "10115",
        country_code: "DE"
      )
    end

    it "pre-fills the invoice generation form from the stored billing details" do
      product = create(:product)
      purchase = create(:purchase, link: product, purchaser: buyer, email: buyer.email)

      visit new_purchase_invoice_path(purchase.external_id, email: purchase.email)

      expect(find_field("Full name").value).to eq("Alice GmbH")
      expect(find_field("Street address").value).to eq("1 Unter den Linden")
      expect(find_field("City").value).to eq("Berlin")
      expect(find_field("ZIP code").value).to eq("10115")
    end
  end
end
