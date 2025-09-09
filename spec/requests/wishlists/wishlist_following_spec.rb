# frozen_string_literal: true

require "spec_helper"

describe "Wishlist following page", :js, type: :system do
  include Rails.application.routes.url_helpers

  let(:user) { create(:user, name: "Follower") }
  let(:wishlist) { create(:wishlist, name: "Followed Wishlist") }
  let!(:wishlist_follower) { create(:wishlist_follower, wishlist:, follower_user: user) }
  let!(:own_wishlist) { create(:wishlist, name: "Own Wishlist", user:) }
  let!(:not_following_wishlist) { create(:wishlist, name: "Not Following") }

  before do
    login_as(user)
  end

  it "lists followed wishlists and allows the user to unfollow" do
    visit wishlists_following_index_path

    expect(page).not_to have_selector(:table_row, { "Name" => own_wishlist.name })
    expect(page).not_to have_selector(:table_row, { "Name" => not_following_wishlist.name })
    within find(:table_row, { "Name" => wishlist.name }) do
      expect(page).to have_link(wishlist.name, href: wishlist_url(wishlist.url_slug, host: wishlist.user.subdomain_with_protocol))

      select_disclosure "Actions" do
        click_on "Unfollow"
      end
    end

    expect(page).to have_alert(text: "You are no longer following Followed Wishlist.")
    expect(page).not_to have_text(wishlist.name)
    expect(wishlist_follower.reload).to be_deleted

    expect(page).to have_text("Follow wishlists that inspire you")
  end
end
