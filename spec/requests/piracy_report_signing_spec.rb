# frozen_string_literal: true

require "spec_helper"

describe "Signing a piracy report notice", type: :system, js: true do
  let(:seller_and_product) { create_piracy_seller_with_product }
  let(:seller) { seller_and_product.first }
  let(:product) { seller_and_product.last }
  let(:report) do
    create(:piracy_report, :awaiting_signature, seller:, product:, url: "https://example.net/design-course",
                                                recipient_name: "Example Net Inc.", recipient_email: "copyright@example.com")
  end

  before do
    report.update!(notice_text: PiracyReports::NoticeRenderer.new(report).call)
    login_as(seller)
  end

  it "signs once every confirmation is checked, and puts the signature in the notice" do
    visit piracy_report_path(report.external_id)

    PiracyReport::SIGNATURE_CONFIRMATIONS.each_value { |text| check(text) }
    fill_in "Type your full legal name to sign", with: "Jane Doe"
    click_on "Sign notice"

    expect(page).to have_text("Signed by Jane Doe")
    expect(find("pre#notice")).to have_text("Signed: /s/ Jane Doe")
    expect(report.reload).to have_attributes(state: "signed", signature_statement_version: PiracyReport::SIGNATURE_STATEMENT_VERSION)
  end

  it "lists the report and links back to it from the list" do
    visit piracy_report_path(report.external_id)
    expect(page).to have_text("Ready for you to sign")
    expect(page).to have_text("You reported the page")

    click_on "Back to piracy reports"

    expect(page).to have_table_row({ "Reported page" => "example.net/design-course", "Status" => "Ready for you to sign" })
    click_on "example.net/design-course"
    expect(page).to have_current_path(piracy_report_path(report.external_id))
  end

  it "sends a seller with no reports to Products to start one" do
    other_seller, = create_piracy_seller_with_product
    login_as(other_seller)

    visit piracy_reports_path
    expect(page).to have_text("No piracy reports yet")
    within("main") { click_on "Products" }

    expect(page).to have_current_path(products_path)
  end

  it "cancels a signed report after the seller confirms" do
    visit piracy_report_path(report.external_id)
    PiracyReport::SIGNATURE_CONFIRMATIONS.each_value { |text| check(text) }
    fill_in "Type your full legal name to sign", with: "Jane Doe"
    click_on "Sign notice"
    expect(page).to have_text("Signed by Jane Doe")

    click_on "Cancel report"
    within_modal "Cancel this report?" do
      click_on "Cancel report"
    end

    expect(page).to have_text("This report was cancelled. We did not send the notice.")
    expect(page).to have_text("Cancelled")
    expect(page).not_to have_button("Cancel report")
    expect(report.reload.state).to eq("cancelled")
  end
end
