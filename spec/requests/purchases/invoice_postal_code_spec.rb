# frozen_string_literal: true

require "spec_helper"

describe "Invoice postal-code requirements", type: :system, js: true do
  let(:purchase) { create(:free_purchase, email: "buyer@example.com") }

  before do
    allow_any_instance_of(PDFKit).to receive(:to_pdf).and_return("")
    allow_any_instance_of(Purchase).to receive(:upload_invoice_pdf).and_return(double(presigned_url: "https://example.com/invoice.pdf"))
    visit new_purchase_invoice_path(purchase.external_id, email: purchase.email)
    page.execute_script("window.open = () => null")
    fill_in "Full name", with: "Buyer"
    fill_in "Street address", with: "1 Main Street"
    fill_in "City", with: "City"
  end

  ["Botswana", "Gambia"].each do |country|
    it "generates an invoice for #{country} without a postal code" do
      select country, from: "Country"
      expect(page).not_to have_field("ZIP code")
      expect(page).not_to have_field("State")
      click_on "Download"
      expect(page).to have_link("here", href: "https://example.com/invoice.pdf")
    end
  end

  it "restores required ZIP and state validation when switching back to the US" do
    select "Botswana", from: "Country"
    expect(page).not_to have_field("ZIP code")
    select "United States", from: "Country"
    fill_in "State", with: ""
    fill_in "ZIP code", with: ""
    click_on "Download"
    expect(find_field("State").find(:xpath, "ancestor::fieldset[1]")[:class]).to include("danger")
    expect(find_field("ZIP code").find(:xpath, "ancestor::fieldset[1]")[:class]).to include("danger")
    expect(page).not_to have_link("here")
    fill_in "State", with: "CA"
    fill_in "ZIP code", with: "94103"
    click_on "Download"
    expect(page).to have_link("here", href: "https://example.com/invoice.pdf")
  end
end
