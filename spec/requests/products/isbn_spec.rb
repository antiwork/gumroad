# frozen_string_literal: true

require "spec_helper"

describe "ISBN functionality", type: :system, js: true do
  let(:seller) { create(:named_seller) }

  before do
    login_as seller
  end

  describe "ebook ISBN editing" do
    it "shows ISBN field for ebook products" do
      visit new_product_path
      fill_in("Name", with: "Test Ebook")
      choose("E-book")
      fill_in("Price", with: 1)
      click_on("Next: Customize")

      expect(page).to have_field("ISBN")
    end

    it "saves ISBN for ebook products" do
      visit new_product_path
      fill_in("Name", with: "Test Ebook with ISBN")
      choose("E-book")
      fill_in("Price", with: 1)
      click_on("Next: Customize")

      fill_in("ISBN", with: "978-0-123456-47-2")
      click_on("Save and continue")

      wait_for_ajax

      product = seller.links.last
      expect(product.isbn).to eq("9780123456472")
    end

    it "includes JSON-LD structured data for ebooks with ISBN" do
      ebook = create(:product, user: seller, native_type: "ebook", isbn: "9780123456472")
      
      visit ebook.long_url

      expect(page).to have_xpath("//script[@type='application/ld+json']", visible: false)
      
      json_ld = page.find("script[type='application/ld+json']", visible: false).text(:all)
      structured_data = JSON.parse(json_ld)
      
      expect(structured_data["@type"]).to eq("Book")
      expect(structured_data["isbn"]).to eq("9780123456472")
    end
  end
end