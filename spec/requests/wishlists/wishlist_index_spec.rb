# frozen_string_literal: true

require "spec_helper"

describe "Wishlist index page", :js, type: :system do
  let(:wishlist) { create(:wishlist, name: "My Wishlist", user: create(:user, name: "Wishlist User")) }
  let(:quantity_item) { create(:wishlist_product, :with_quantity, wishlist:) }
  let(:variant_item) { create(:wishlist_product, :with_recurring_variant, wishlist:) }

  before do
    login_as(wishlist.user)

    quantity_item.product.update!(name: "Quantity Product")
    variant_item.product.update!(name: "Variant Product")
  end

  it "lists wishlists and links to the public page" do
    visit wishlists_path

    within find(:table_row, { "Name" => wishlist.name }) do
      new_window = window_opened_by { click_link(wishlist.name) }

      within_window new_window do
        expect(page).to have_current_path(Rails.application.routes.url_helpers.wishlist_path(wishlist.url_slug))
        expect(page).to have_text("My Wishlist")
      end
    end
  end

  it "allows the user to delete a wishlist" do
    visit wishlists_path

    within find(:table_row, { "Name" => wishlist.name }) do
      find("button[aria-label='Delete wishlist']").click
    end

    click_on "Yes, delete"

    expect(page).to have_text("Wishlist deleted")
    expect(page).not_to have_text(wishlist.name)
    expect(wishlist.reload).to be_deleted
  end

  context "for a different user" do
    before { wishlist.update!(user: create(:user)) }

    it "does not show the wishlist" do
      visit wishlists_path

      within_section "Save products you are wishing for" do
        expect(page).to have_text("Bookmark and organize your desired products with ease")
      end
    end
  end

  context "reviews_page feature flag is disabled" do
    it "does not show the reviews tab" do
      visit wishlists_path
      expect(page).to_not have_link("Reviews")
    end
  end

  context "reviews_page feature flag is enabled" do
    before { Feature.activate_user(:reviews_page, wishlist.user) }

    it "shows the reviews tab" do
      visit wishlists_path
      expect(page).to have_selector("a[role='tab'][href='#{reviews_path}'][aria-selected='false']", text: "Reviews")
    end
  end
end
