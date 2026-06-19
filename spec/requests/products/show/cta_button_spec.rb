# frozen_string_literal: true

require "spec_helper"

describe "Product page CTA button for a returning buyer", :js, type: :system do
  let(:seller) { create(:named_user) }
  let(:buyer) { create(:user) }

  context "when the buyer's only prior purchase of the product was free" do
    let(:product) { create(:product, user: seller, price_cents: 0) }

    before do
      create(:free_purchase, link: product, purchaser: buyer, email: buyer.email)
      login_as buyer
    end

    it "shows the regular CTA instead of 'Purchase again'" do
      visit short_link_path(product)

      expect(page).to have_link("I want this!")
      expect(page).to have_no_link("Purchase again")
    end
  end

  context "when the buyer previously paid for the product" do
    let(:product) { create(:product, user: seller, price_cents: 500) }

    before do
      create(:purchase, link: product, purchaser: buyer, email: buyer.email)
      login_as buyer
    end

    it "shows 'Purchase again'" do
      visit short_link_path(product)

      expect(page).to have_link("Purchase again")
    end
  end
end
