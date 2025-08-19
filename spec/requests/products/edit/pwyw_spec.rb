# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit pay what you want setting", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product_with_pdf_file, user: seller, size: 1024, custom_receipt: "Thanks!") }

  include_context "with switching account to user as admin for seller"

  it "displays the setting" do
    visit edit_link_path(product.unique_permalink)
    fill_in("Amount", with: "0")
    check "Allow customers to pay what they want"

    expect(page).to have_field("Minimum amount", disabled: true)
    expect(page).to have_field("Suggested amount")
    expect(page).to have_field("Allow customers to pay what they want")
    save_change
    wait_for_ajax
    expect(product.reload.customizable_price).to eq(true)
    expect(page).to have_field("Minimum amount", disabled: true)
  end

  it "tests that PWYW is still available" do
    visit edit_link_path(product.unique_permalink)
    fill_in "Amount", with: "0"
    check "Allow customers to pay what they want"
    fill_in "Suggested amount", with: "10"
    save_change
    wait_for_ajax
    in_preview do
      expect(page).to have_selector("[itemprop='price']", text: "$0+")
    end
    expect(product.reload.suggested_price_cents).to eq(10_00)
    expect(find_field("Suggested amount").value).to eq "10"
  end
end
