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

  describe "custom fees" do
    context "when the user has a custom direct fee percentage" do
      before do
        user.update(custom_direct_fee_per_thousand: 50)
      end

      it "shows the custom direct fee percentage" do
        visit admin_user_path(user.id)

        expect(page).to have_text("Custom fee: 5.0%")
      end
    end

    context "when the user does not have a custom direct fee percentage" do
      it "does not show the custom direct fee percentage" do
        visit admin_user_path(user.id)

        expect(page).not_to have_text("Custom fee:")
      end
    end

    it "allows updating the custom fee percentage" do
      visit admin_user_path(user.id)

      find_and_click "h3", text: "Custom direct fee"
      fill_in "custom_direct_fee[percentage]", with: "10.00"
      click_button(id: "update-custom-direct-fee")
      accept_browser_dialog
      wait_for_ajax

      expect(user.reload.custom_direct_fee_per_thousand).to eq(100)
    end

    it "allows removing the custom direct fee percentage" do
      user.update(custom_direct_fee_per_thousand: 150)
      visit admin_user_path(user.id)

      find_and_click "h3", text: "Custom direct fee"
      fill_in "custom_direct_fee[percentage]", with: ""
      click_button(id: "update-custom-direct-fee")
      accept_browser_dialog
      wait_for_ajax

      expect(user.reload.custom_direct_fee_per_thousand).to be_nil
    end
  end

  def accept_browser_dialog
    wait = Selenium::WebDriver::Wait.new(timeout: 30)
    wait.until do
      page.driver.browser.switch_to.alert
      true
    rescue Selenium::WebDriver::Error::NoAlertPresentError
      false
    end
    page.driver.browser.switch_to.alert.accept
  end
end
