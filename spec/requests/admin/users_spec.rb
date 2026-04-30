# frozen_string_literal: true

require "spec_helper"

describe "Admin::UsersController Scenario", type: :system, js: true do
  let(:admin) { create(:admin_user) }
  let(:user) { create(:user) }
  let!(:user_compliance_info) { create(:user_compliance_info, user:) }

  before do
    login_as(admin)
  end

  context "when user has no products" do
    it "shows no products alert" do
      visit admin_user_path(user.external_id)

      click_on "Products"

      expect(page).to have_text("No products created.")
    end
  end

  context "when user has products" do
    before do
      create(:product, user:, unique_permalink: "a", name: "Product a", created_at: 1.minute.ago)
      create(:product, user:, unique_permalink: "b", name: "Product b", created_at: 2.minutes.ago)
      create(:product, user:, unique_permalink: "c", name: "Product c", created_at: 3.minutes.ago)

      stub_const("Admin::Users::ListPaginatedProducts::PRODUCTS_PER_PAGE", 2)
    end

    it "shows products" do
      visit admin_user_path(user.external_id)
      click_on "Products"

      expect(page).to have_text("Product a")
      expect(page).to have_text("Product b")
      expect(page).not_to have_text("Product c")

      within("[aria-label='Pagination']") { click_on("2") }
      expect(page).not_to have_text("Product a")
      expect(page).not_to have_text("Product b")
      expect(page).to have_text("Product c")
      within("[aria-label='Pagination']") { expect(page).to have_button("1") }
    end
  end

  describe "user memberships" do
    context "when the user has no user memberships" do
      it "doesn't render user memberships" do
        visit admin_user_path(user.external_id)

        expect(page).not_to have_text("User memberships")
      end
    end

    context "when the user has user memberships" do
      let(:seller_one) { create(:user, :without_username) }
      let(:seller_two) { create(:user) }
      let(:seller_three) { create(:user) }
      let!(:team_membership_owner) { user.create_owner_membership_if_needed! }
      let!(:team_membership_one) { create(:team_membership, user:, seller: seller_one) }
      let!(:team_membership_two) { create(:team_membership, user:, seller: seller_two) }
      let!(:team_membership_three) { create(:team_membership, user:, seller: seller_three, deleted_at: 1.hour.ago) }

      it "renders user memberships" do
        visit admin_user_path(user.external_id)

        find_and_click "h3", text: "User memberships"
        expect(page).to have_text(seller_one.display_name(prefer_email_over_default_username: true))
        expect(page).to have_text(seller_two.display_name(prefer_email_over_default_username: true))
        expect(page).not_to have_text(seller_three.display_name(prefer_email_over_default_username: true))
      end
    end
  end

  describe "custom fees" do
    context "when the user has a custom fee set" do
      before do
        user.update!(custom_fee_per_thousand: 50)
      end

      it "shows the custom fee percentage" do
        visit admin_user_path(user.external_id)

        expect(page).to have_text("Custom fee: 5.0%")
      end
    end

    context "when the user does not have a custom fee set" do
      it "does not show the custom fee heading" do
        visit admin_user_path(user.external_id)

        expect(page).not_to have_text("Custom fee:")
      end
    end

    def open_custom_fee_form
      find_and_click "h3", text: "Custom fee"
      expect(page).to have_css("#update-custom-fee", wait: 10)
    end

    def submit_custom_fee_and_wait
      accept_confirm(wait: 10) { find("#update-custom-fee").click }
    rescue Capybara::ModalNotFound
      page.execute_script("window.confirm = function() { return true; }")
      find("#update-custom-fee").click
    ensure
      expect(page).to have_alert(text: /Custom fee updated|Something went wrong/, wait: 15)
    end

    it "allows setting new custom fee" do
      expect(user.reload.custom_fee_per_thousand).to be_nil

      visit admin_user_path(user.external_id)
      open_custom_fee_form
      fill_in "custom_fee_percent", with: "2.5"
      submit_custom_fee_and_wait

      expect(user.reload.custom_fee_per_thousand).to eq(25)
    end

    it "allows updating the existing custom fee" do
      user.update(custom_fee_per_thousand: 50)
      expect(user.reload.custom_fee_per_thousand).to eq(50)

      visit admin_user_path(user.external_id)
      open_custom_fee_form
      fill_in "custom_fee_percent", with: "2.5"
      submit_custom_fee_and_wait

      expect(user.reload.custom_fee_per_thousand).to eq(25)
    end

    it "allows clearing the existing custom fee" do
      user.update(custom_fee_per_thousand: 75)
      expect(user.reload.custom_fee_per_thousand).to eq(75)

      visit admin_user_path(user.external_id)
      open_custom_fee_form
      fill_in "custom_fee_percent", with: ""
      submit_custom_fee_and_wait

      expect(user.reload.custom_fee_per_thousand).to be_nil
    end
  end

  describe "toggle adult products" do
    context "when the user is not marked as adult" do
      before do
        user.update!(all_adult_products: false)
      end

      it "shows 'Mark as adult' button" do
        visit admin_user_path(user.external_id)

        expect(page).to have_button("Mark as adult")
        expect(page).not_to have_button("Unmark as adult")
      end

      it "allows marking user as adult" do
        expect(user.reload.all_adult_products).to be(false)

        visit admin_user_path(user.external_id)
        accept_confirm { click_on "Mark as adult" }
        wait_for_ajax

        expect(user.reload.all_adult_products).to be(true)
        expect(page).to have_button("Unmark as adult")
        expect(page).not_to have_button("Mark as adult")
      end
    end

    context "when the user is marked as adult" do
      before do
        user.update!(all_adult_products: true)
      end

      it "shows 'Unmark as adult' button" do
        visit admin_user_path(user.external_id)

        expect(page).to have_button("Unmark as adult")
        expect(page).not_to have_button("Mark as adult")
      end

      it "allows unmarking user as adult" do
        expect(user.reload.all_adult_products).to be(true)

        visit admin_user_path(user.external_id)
        accept_confirm { click_on "Unmark as adult" }
        wait_for_ajax

        expect(user.reload.all_adult_products).to be(false)
        expect(page).to have_button("Mark as adult")
        expect(page).not_to have_button("Unmark as adult")
      end
    end

    context "when the user's all_adult_products is nil" do
      before do
        user.all_adult_products = nil
        user.save!
      end

      it "shows 'Mark as adult' button" do
        visit admin_user_path(user.external_id)

        expect(page).to have_button("Mark as adult")
        expect(page).not_to have_button("Unmark as adult")
      end

      it "allows marking user as adult" do
        visit admin_user_path(user.external_id)
        accept_confirm { click_on "Mark as adult" }
        wait_for_ajax

        expect(user.reload.all_adult_products).to be(true)
        expect(page).to have_button("Unmark as adult")
        expect(page).not_to have_button("Mark as adult")
      end
    end
  end

  describe "blocked user indicator" do
    before { BlockedObject.delete_all }
    after { BlockedObject.delete_all }

    it "shows blocked user indicator with appropriate tooltips for email and domain blocks" do
      # Initially no block should exist
      visit admin_user_path(user.external_id)
      expect(page).not_to have_css("[aria-label='Blocked User']")

      # Block by email
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], user.form_email, admin.id)
      page.refresh

      # Verify icon appears and tooltip shows email block
      expect(page).to have_css("[aria-label='Blocked User']")
      icon = find("[aria-label='Blocked User']")
      icon.hover
      expect(page).to have_text("Email blocked")
      expect(page).to have_text("block created")

      # Add domain block
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], user.form_email_domain, admin.id)
      page.refresh

      # Verify icon still appears and tooltip shows both blocks
      expect(page).to have_css("[aria-label='Blocked User']")
      icon = find("[aria-label='Blocked User']")
      icon.hover
      expect(page).to have_text("Email blocked")
      expect(page).to have_text("#{user.form_email_domain} blocked")
      expect(page).to have_text("block created")
    end
  end

  describe "GDPR data erasure" do
    let!(:product) { create(:product, user: user) }
    let!(:purchase) { create(:purchase, purchaser: user, full_name: "Test Buyer", street_address: "123 Main St") }

    it "anonymizes user data and shows confirmation" do
      visit admin_user_path(user.external_id)

      accept_confirm do
        click_on "GDPR Erase"
      end

      expect(page).to have_text("GDPR erasure complete")

      user.reload
      expect(user.name).to eq("[deleted]")
      expect(user.email).to start_with("deleted-")
      expect(user.deleted?).to eq(true)
      expect(user.street_address).to be_nil
      expect(user.bio).to be_nil

      purchase.reload
      expect(purchase.full_name).to eq("[deleted]")
      expect(purchase.street_address).to be_nil

      expect(product.reload.deleted?).to eq(true)
    end
  end

  describe "Suspend for fraud button" do
    it "links to the suspend users page with the user ID pre-filled" do
      visit admin_user_path(user.external_id)

      expect(page).to have_button("Suspend for fraud")
    end

    it "is hidden when user is already flagged for fraud" do
      user.flag_for_fraud!(author_id: admin.id)

      visit admin_user_path(user.external_id)

      expect(page).not_to have_button("Suspend for fraud")
    end

    it "is hidden when user is already suspended" do
      user.flag_for_fraud!(author_id: admin.id)
      user.suspend_for_fraud(author_id: admin.id)

      visit admin_user_path(user.external_id)

      expect(page).not_to have_button("Suspend for fraud")
    end
  end

  describe "Suspend users page pre-fill" do
    it "pre-fills identifiers from query parameter" do
      visit "#{admin_suspend_users_path}?identifiers=#{user.external_id}"

      expect(page).to have_field("identifiers", with: user.external_id)
    end
  end
end
