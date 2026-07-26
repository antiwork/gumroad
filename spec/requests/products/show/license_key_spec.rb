# frozen_string_literal: true

require "spec_helper"

describe "License key on the product page", :js, type: :system do
  let(:seller) { create(:named_user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product, user: seller, is_licensed: true) }

  context "when a signed-in buyer already owns the licensed product" do
    let!(:purchase) { create(:free_purchase, link: product, purchaser: buyer, email: buyer.email) }
    let!(:license) { create(:license, link: product, purchase:) }

    before { login_as buyer }

    it "shows the license key inline so the buyer does not have to open the content page" do
      visit short_link_path(product)

      expect(page).to have_text("You already own this product")
      expect(page).to have_text("License key")
      expect(page).to have_text(license.serial)
      expect(page).to have_button("Copy")
    end
  end

  context "when the visitor is not a recognized buyer" do
    it "links the license key lookup page" do
      visit short_link_path(product)

      expect(page).to have_text("Already bought this?")
      expect(page).to have_link("View your information", href: license_key_lookup_path)
    end
  end

  context "when the product is not licensed" do
    let(:product) { create(:product, user: seller) }

    it "does not offer the license key lookup" do
      visit short_link_path(product)

      expect(page).to have_no_text("Already bought this?")
    end
  end
end
