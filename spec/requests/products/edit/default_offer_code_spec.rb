# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit Default Offer Code", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller, price_cents: 10000) }

  include_context "with switching account to user as admin for seller"

  describe "when offer codes exist" do
    let!(:offer_code) do
      create(:offer_code, user: seller, products: [product],
             name: "Black Friday", code: "BLACKFRIDAY",
             amount_cents: nil, amount_percentage: 20)
    end

    it "allows selecting and saving a default offer code" do
      visit edit_link_path(product.unique_permalink)

      within_section "Pricing" do
        check "Apply discount"
        select "Black Friday", from: "Discount code"
      end

      save_change
      expect(product.reload.default_offer_code).to eq(offer_code)
    end

    it "allows clearing a default offer code" do
      product.update!(default_offer_code: offer_code)

      visit edit_link_path(product.unique_permalink)

      within_section "Pricing" do
        click_button "Clear discount code"
      end

      save_change
      expect(product.reload.default_offer_code).to be_nil
    end

    it "shows discount badge in preview when offer code selected" do
      visit edit_link_path(product.unique_permalink)

      within_section "Pricing" do
        check "Apply discount"
        select "Black Friday", from: "Discount code"
      end

      expect(page).to have_text("20% off will be applied at checkout (Code BLACKFRIDAY)")
    end

    it "persists the selection after page reload" do
      product.update!(default_offer_code: offer_code)

      visit edit_link_path(product.unique_permalink)

      within_section "Pricing" do
        expect(page).to have_checked_field("Apply discount")
        expect(page).to have_select("Discount code", selected: "Black Friday")
      end
    end
  end

  describe "when no offer codes exist" do
    it "does not show the apply discount toggle" do
      visit edit_link_path(product.unique_permalink)

      expect(page).not_to have_text("Apply discount")
    end
  end
end
