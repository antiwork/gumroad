# frozen_string_literal: true

require "spec_helper"

describe "Tax Center", js: true, type: :system do
  let(:seller_created_at) { Date.new(4.years.ago.year, 6, 15) }
  let(:seller) { create(:user, created_at: seller_created_at) }

  before do
    Feature.activate_user(:tax_center, seller)

    login_as seller
  end

  it "renders with correct data" do
    year_1 = seller_created_at.year + 1
    year_2 = seller_created_at.year + 2

    create(:user_tax_form, user: seller, tax_year: year_1, tax_form_type: "us_1099_k")
    create(:user_tax_form, user: seller, tax_year: year_2, tax_form_type: "us_1099_k")

    product = create(:product, user: seller, price_cents: 1000)
    create(:purchase, :with_custom_fee, link: product, created_at: Date.new(year_1, 3, 15), fee_cents: 100, tax_cents: 15)
    create(:purchase, :with_custom_fee, link: product, created_at: Date.new(year_2, 6, 10), fee_cents: 50)

    visit tax_center_path
    expect(page).to have_select("Tax year", selected: (Time.current.year - 1).to_s)
    expect(page).to have_text("Let's get your tax info ready")
    expect(page).to have_text("Your 1099-K will appear here once it's available")
    expect(page).not_to have_table("Tax documents")

    select year_1.to_s, from: "Tax year"
    wait_for_ajax

    expect(page).to_not have_text("Let's get your tax info ready")
    expect(page).to have_table("Tax documents", with_rows: [
                                 {
                                   "Document" => "1099-K",
                                   "Type" => "IRS form",
                                   "Gross" => "$10.00",
                                   "Fees" => "-$1.00",
                                   "Taxes" => "-$0.15",
                                   "Affiliate commission" => "-$0.00",
                                   "Net" => "$8.85"
                                 }
                               ])

    select year_2.to_s, from: "Tax year"
    wait_for_ajax

    expect(page).to have_select("Tax year", selected: year_2.to_s)
    expect(page).to have_table("Tax documents", with_rows: [
                                 {
                                   "Document" => "1099-K",
                                   "Type" => "IRS form",
                                   "Gross" => "$10.00",
                                   "Fees" => "-$0.50",
                                   "Taxes" => "-$0.00",
                                   "Affiliate commission" => "-$0.00",
                                   "Net" => "$9.50"
                                 }
                               ])
  end
end
