# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe("Followers", js: true, type: :system) do
  let(:seller) { create(:named_seller) }

  before do
    @page_limit = FollowersController::FOLLOWERS_PER_PAGE
    @identifiable_follower = create(:follower, user: create(:user), followed_id: seller.id, follower_user_id: create(:user).id, email: "test@example.com", source: Follower::From::PROFILE_PAGE, created_at: Date.today, confirmed_at: Date.today)
  end

  include_context "with switching account to user as admin for seller"

  it_behaves_like "creator dashboard page", "Emails" do
    let(:path) { followers_path }
  end

  describe "no followers scenario" do
    before do
      Follower.destroy_all
      visit followers_path
    end

    it "displays no followers message" do
      expect(page).to have_content("Manage all of your followers in one place.")
      expect(page).to have_content("Interacting with and serving your audience is an important part of running your business.")
      expect(page).to have_button("Share subscribe page")
    end
  end

  describe "view followers scenario" do
    before do
      @confirmed_followers_count = @page_limit + 3
      @unconfirmed_follower = create(:follower, user: create(:user), followed_id: seller.id, follower_user_id: create(:user).id, source: Follower::From::PROFILE_PAGE, created_at: Date.today)
      create(:follower, user: create(:user), followed_id: seller.id, follower_user_id: create(:user).id, source: Follower::From::PROFILE_PAGE, created_at: Date.today, deleted_at: Date.today)
      @follower_without_source = create(:follower, user: create(:user), followed_id: seller.id, follower_user_id: create(:user).id, email: "test_nosource@example.com", created_at: Date.today, confirmed_at: Date.yesterday)
      @follower_without_source2 = create(:follower, user: create(:user), followed_id: seller.id, follower_user_id: create(:user).id, email: "test_nosource2@example.com", created_at: Date.today, confirmed_at: Date.yesterday)
      @page_limit.times { |x| create(:follower, user: create(:user), followed_id: seller.id, follower_user_id: create(:user).id, source: Follower::From::PROFILE_PAGE, created_at: 1.week.ago, confirmed_at: Date.today) }
      visit followers_path
    end

    it "shows a list of confirmed followers with pagination" do
      tbody = find(:table, "All subscribers (#{@confirmed_followers_count})").find("tbody")
      within tbody do
        expect(page).to have_selector(:table_row, count: @page_limit)
      end
      click_on "Load more"
      within tbody do
        expect(page).to have_selector(:table_row, count: @confirmed_followers_count)
      end
      expect(page).to_not have_button "Load more"
    end

    it "supports search functionality" do
      expect(page).to_not have_selector(:table_row, text: "test@example.com")
      select_disclosure "Search" do
        fill_in("Search followers", with: "FALSE_EMAIL@gumroad")
      end
      expect(page).to_not have_table("All followers")
      expect(page).to_not have_button "Load more"
      expect(page).to have_content("No followers found")

      fill_in("Search followers", with: "test")
      expect(page).to have_selector(:table_row, text: "test@example.com", count: 1)
      expect(page).to have_selector(:table_row, text: "test_nosource@example.com", count: 1)
      expect(page).to have_selector(:table_row, text: "test_nosource2@example.com", count: 1)
      expect(page).to_not have_button "Load more"
    end
  end

  describe "follower drawer" do
    before do
      visit followers_path
    end

    it "shows and hides a drawer with the follower's information" do
      expect(page).to_not have_selector("aside")
      find(:table_row, text: "test@example.com").click
      within "aside" do
        expect(page).to have_selector("h2", text: "Details")
        expect(page).to have_content("test@example.com")
        click_on "Close"
      end
      expect(page).to_not have_selector("aside")
    end

    it "deletes a follower" do
      find(:table_row, text: "test@example.com").click
      click_on "Remove follower"
      wait_for_ajax

      expect(page).to have_content("Follower removed!")
      expect(page).to_not have_selector("aside")

      follower = seller.followers.where(email: "test@example.com").first
      expect(follower.deleted?).to be true
    end
  end

  describe "subscribe page" do
    it "allows copying the subscribe page URL to the clipboard" do
      visit followers_path
      share_button = find_button("Share subscribe page")
      share_button.hover
      expect(share_button).to have_tooltip(text: "Copy to Clipboard")
      share_button.click
      expect(share_button).to have_tooltip(text: "Copied!")
    end
  end
end
