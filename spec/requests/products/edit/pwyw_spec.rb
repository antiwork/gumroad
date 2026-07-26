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

    pwyw_toggle = find_field("Allow customers to pay what they want", disabled: true)
    expect(pwyw_toggle).to be_checked

    expect(page).to have_field("Suggested amount")
    # The product's Amount is $0, so paying nothing is allowed but a customer who chooses to pay
    # still has to clear USD's processing minimum.
    expect(page).to have_text("Customers can pay nothing, or at least $0.99 if they choose to pay")
    save_change
    wait_for_ajax
    expect(product.reload.customizable_price).to eq(true)
    expect(page).to have_text("Customers can pay nothing, or at least $0.99 if they choose to pay")
  end

  it "tests that PWYW is still available" do
    visit edit_link_path(product.unique_permalink)
    fill_in "Amount", with: "0"

    pwyw_toggle = find_field("Allow customers to pay what they want", disabled: true)
    expect(pwyw_toggle).to be_checked

    fill_in "Suggested amount", with: "10"
    save_change
    wait_for_ajax
    in_preview do
      expect(page).to have_selector("[itemprop='price']", text: "$0+")
    end
    expect(product.reload.suggested_price_cents).to eq(10_00)
    expect(find_field("Suggested amount").value).to eq "10"
  end

  it "hides info alert and enables toggle when price is changed from $0 to a positive value" do
    visit edit_link_path(product.unique_permalink)
    fill_in "Amount", with: "0"

    expect(page).to have_content("Free products require a pay what they want price.")
    pwyw_toggle = find_field("Allow customers to pay what they want", disabled: true)
    expect(pwyw_toggle).to be_checked
    expect(pwyw_toggle).to be_disabled

    fill_in "Amount", with: "10"

    expect(page).not_to have_content("Free products require a pay what they want price.")
    # The note tracks Amount, so raising it from $0 replaces the pay-nothing wording with the floor.
    expect(page).to have_text("Customers must pay at least $10")
    pwyw_toggle = find_field("Allow customers to pay what they want")
    expect(pwyw_toggle).to be_checked
    expect(pwyw_toggle).not_to be_disabled
  end
end
