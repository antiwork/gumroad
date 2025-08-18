# frozen_string_literal: true

require "spec_helper"

describe "Generate invoice confirmation page", type: :system, js: true do
  before :each do
    @purchase = create(:purchase)
  end

  it "asks to confirm the email address before showing the generate invoice page" do
    visit "/purchases/#{@purchase.external_id}/generate_invoice"

    expect(page).to have_current_path(confirm_generate_invoice_path(id: @purchase.external_id))
    expect(page).to have_text "Generate invoice"
    expect(page).to have_text "Please enter the purchase's email address to generate the invoice."

    fill_in "Email address", with: "wrong.email@example.com"
    click_on "Confirm email"

    expect(page).to have_current_path(confirm_generate_invoice_path(id: @purchase.external_id))
    expect(page).to have_alert(text: "Incorrect email address. Please try again.")

    fill_in "Email address", with: @purchase.email
    click_on "Confirm email"

    expect(page).to have_current_path(generate_invoice_by_buyer_path(@purchase.external_id, email: @purchase.email))
    expect(page).to have_text @purchase.link.name

    allow_any_instance_of(PDFKit).to receive(:to_pdf).and_return("")

    invoice_s3_url = "https://s3.example.com/invoice.pdf"
    s3_double = double(presigned_url: invoice_s3_url)
    allow_any_instance_of(Purchase).to receive(:upload_invoice_pdf).and_return(s3_double)

    fill_in "Full name", with: "John Doe"
    fill_in "Street address", with: "123 Main St"
    fill_in "City", with: "San Francisco"
    fill_in "State", with: "CA"
    fill_in "ZIP code", with: "94101"
    select "United States", from: "Country"

    new_window = window_opened_by { click_on "Download" }
    within_window new_window do
      expect(page).to have_current_path(invoice_s3_url)
    end
  end
end
