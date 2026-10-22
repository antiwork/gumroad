# frozen_string_literal: true

require "spec_helper"

describe "Discount schedule validation", type: :system, js: true do
  let(:seller) { create(:named_seller) }

  before do
    create(:product, user: seller, price_cents: 1000)
    login_as seller
    visit checkout_discounts_path
    click_on "New discount"
    fill_in "Name", with: "Scheduled discount"
    check "All products"
    fill_in "Percentage", with: "10"
    check "Limit validity period"
    fill_in_datetime "Valid from", with: "2027-12-02T23:00"
    uncheck "No end date"
    fill_in_datetime "Valid until", with: "2027-11-02T23:00"
  end

  it "saves without dates when scheduling is disabled despite a retained invalid range" do
    uncheck "Limit validity period"
    click_on "Add discount"
    expect(page).to have_alert(text: "Successfully created discount!")
    offer_code = seller.offer_codes.sole
    expect(offer_code.valid_at).to be_nil
    expect(offer_code.expires_at).to be_nil
    expect(offer_code.amount_percentage).to eq(10)
  end

  it "still rejects an enabled invalid range and permits selecting no end date" do
    click_on "Add discount"
    expect(find_field("Valid until")["aria-invalid"]).to eq("true")
    expect(seller.offer_codes.count).to eq(0)
    check "No end date"
    click_on "Add discount"
    expect(page).to have_alert(text: "Successfully created discount!")
    expect(seller.offer_codes.sole.valid_at).to be_present
    expect(seller.offer_codes.sole.expires_at).to be_nil
  end

  it "saves an enabled valid range after correcting its end" do
    fill_in_datetime "Valid until", with: "2027-12-03T23:00"
    click_on "Add discount"
    expect(page).to have_alert(text: "Successfully created discount!")
    offer_code = seller.offer_codes.sole
    expect(offer_code.expires_at).to be > offer_code.valid_at
  end
end
