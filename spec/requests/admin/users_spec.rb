# frozen_string_literal: true

require "spec_helper"

describe "Admin::UsersController Scenario", type: :feature, js: true do
  let(:admin) { create(:admin_user, has_risk_privilege: true, has_payout_privilege: true) }
  let(:user) { create(:user) }
  let!(:user_compliance_info) { create(:user_compliance_info, user:) }

  before do
    login_as(admin)
  end

  context "when user has no products" do
    it "shows no products alert" do
      visit admin_user_path(user.id)

      expect(page).to have_text("No products created.")
    end
  end

  context "when user has products" do
    before do
      %w(a b c).each_with_index do |l, i|
        create(:product, user:, unique_permalink: l, name: "Product #{l}", created_at: i.minutes.ago)
      end
      stub_const("Admin::UsersController::PRODUCTS_PER_PAGE", 2)
    end

    it "shows products" do
      visit admin_user_path(user.id)

      expect(page).to have_text("Product a")
      expect(page).to have_text("Product b")
      expect(page).not_to have_text("Product c")

      within("[aria-label='Pagination']") { click_on("2") }
      expect(page).not_to have_text("Product a")
      expect(page).not_to have_text("Product b")
      expect(page).to have_text("Product c")
      within("[aria-label='Pagination']") { expect(page).to have_link("1") }
    end
  end

  describe "user memberships" do
    context "when the user has no user memberships" do
      it "doesn't render user memberships" do
        visit admin_user_path(user.id)

        expect(page).not_to have_text("User memberships")
      end
    end

    context "whent the user has user memberships" do
      let(:seller_one) { create(:user, :without_username) }
      let(:seller_two) { create(:user) }
      let(:seller_three) { create(:user) }
      let!(:team_membership_owner) { user.create_owner_membership_if_needed! }
      let!(:team_membership_one) { create(:team_membership, user:, seller: seller_one) }
      let!(:team_membership_two) { create(:team_membership, user:, seller: seller_two) }
      let!(:team_membership_three) { create(:team_membership, user:, seller: seller_three, deleted_at: 1.hour.ago) }

      it "renders user memberships" do
        visit admin_user_path(user.id)

        find_and_click "h3", text: "User memberships"
        expect(page).to have_text(seller_one.display_name(prefer_email_over_default_username: true))
        expect(page).to have_text(seller_two.display_name(prefer_email_over_default_username: true))
        expect(page).not_to have_text(seller_three.display_name(prefer_email_over_default_username: true))
      end
    end
  end
end
