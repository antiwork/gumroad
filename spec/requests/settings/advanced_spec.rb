# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Advanced Settings Scenario", type: :system, js: true) do
  let(:seller) { create(:user, name: "Gum") }

  describe "deleting the gumroad account" do
    context "when logged user has role admin" do
      include_context "with switching account to user as admin for seller"

      it "does not show Danger Zone" do
        visit settings_advanced_path

        expect(page).not_to have_text("Danger Zone")
        expect(page).not_to have_link("Delete your Gumroad account")
      end
    end

    context "when logged user is owner" do
      before do
        login_as seller
        stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)  # For negative credits
      end

      it "allows deletion" do
        visit(settings_advanced_path)
        click_on "Delete your Gumroad account"
        click_on "Yes, delete my account"

        expect_alert_message("Your account has been successfully deleted.")
        expect(page).to have_current_path(login_path, ignore_query: true)
        expect(seller.reload.deleted?).to eq(true)
      end

      it "does not allow deletion if there is an unpaid balance pending" do
        create(:balance, user: seller, amount_cents: 10)
        visit(settings_advanced_path)
        click_on "Delete your Gumroad account"
        click_on "Yes, delete my account"

        expect_alert_message("Cannot delete due to an unpaid balance of $0.10.")
        expect(seller.reload.deleted?).to eq(false)
      end

      describe "when the feature delete_account_forfeit_balance is active" do
        before do
          Feature.activate_user :delete_account_forfeit_balance, seller
        end

        it "allows deletion if there is a positive unpaid balance pending" do
          balance = create(:balance, user: seller, amount_cents: 10)

          visit(settings_advanced_path)
          click_on "Delete your Gumroad account"

          expect(page).to have_text "You have a balance of $0.10. To delete your account, you will need to forfeit your balance."
          click_on "Yes, forfeit balance and delete"

          expect_alert_message("Your account has been successfully deleted.")
          expect(page).to have_current_path(login_path, ignore_query: true)
          expect(seller.reload.deleted?).to eq(true)
          expect(balance.reload.state).to eq("forfeited")
        end

        it "does not allow deletion if there is a negative unpaid balance pending" do
          create(:balance, user: seller, amount_cents: -10)
          visit(settings_advanced_path)
          click_on "Delete your Gumroad account"
          click_on "Yes, delete my account"

          expect_alert_message("Cannot delete due to an unpaid balance of $-0.10.")
          expect(seller.reload.deleted?).to eq(false)
        end
      end
    end

    it "logs out of all the existing sessions" do
      Capybara.using_session(:session_1) do
        login_as seller
        visit settings_main_path
      end

      Capybara.using_session(:session_2) do
        login_as seller
        visit settings_main_path
      end

      login_as seller
      visit settings_advanced_path
      click_on "Delete your Gumroad account"
      click_on "Yes, delete my account"

      expect_alert_message("Your account has been successfully deleted.")
      expect(page).to have_current_path(login_path, ignore_query: true)

      Capybara.using_session(:session_1) do
        refresh
        expect_alert_message("We're sorry; you have been logged out. Please login again.")
        expect(page).to have_current_path(login_path, ignore_query: true)
      end

      Capybara.using_session(:session_2) do
        refresh
        expect_alert_message("We're sorry; you have been logged out. Please login again.")
        expect(page).to have_current_path(login_path, ignore_query: true)
      end
    end
  end

  describe "Custom domain" do
    let(:user) { create(:user) }
    let(:valid_domain) { "valid-domain.com" }
    let(:invalid_domain) { "invalid-domain.com" }

    before do
      expect(CustomDomainVerificationService)
        .to receive(:new)
        .twice
        .with(domain: valid_domain)
        .and_return(double(process: true))

      expect(CustomDomainVerificationService)
      .to receive(:new)
      .twice
      .with(domain: invalid_domain)
      .and_return(double(process: false))

      login_as user
    end

    it "allows validating the custom domain configuration and also mark it as verified/unverified accordingly on saving the specified domain" do
      visit settings_advanced_path

      # Specify invalid domain
      fill_in "Domain", with: invalid_domain
      # Save it
      expect do
        click_on "Update settings", match: :first
        wait_for_ajax
      end.to change { user.reload.custom_domain&.domain }.from(nil).to(invalid_domain)
      expect(user.reload.custom_domain.failed_verification_attempts_count).to eq(0)
      expect(user.custom_domain.verified?).to eq(false)

      visit settings_advanced_path
      within_section("Custom domain", section_element: :section) do
        expect(page).to have_text("Domain verification failed. Please make sure you have correctly configured the DNS" \
                                  " record for invalid-domain.com.")
      end

      # Specify blank domain
      fill_in "Domain", with: "      "
      expect(page).not_to have_button("Verify")

      # Specify valid domain
      fill_in "Domain", with: valid_domain
      # Test the domain configuration
      click_on "Verify"
      wait_for_ajax
      within_section("Custom domain", section_element: :section) do
        expect(page).to have_text("valid-domain.com domain is correctly configured!")
      end
      # Save it
      expect do
        click_on "Update settings", match: :first
        wait_for_ajax
        expect(page).to have_alert(text: "Your account has been updated!")
        expect(page).to have_button("Update settings")
      end.to change { user.reload.custom_domain.domain }.from(invalid_domain).to(valid_domain)
        .and change { user.custom_domain.verified? }.from(false).to(true)
    end
  end

  describe "Mass-block emails" do
    before do
      ["customer1@example.com", "customer2@example.com"].each do |email|
        BlockedCustomerObject.block_email!(email:, seller_id: seller.id)
      end

      login_as seller
      visit settings_advanced_path
    end

    it "allows mass blocking customer emails by automatically sanitizing and normalizing them" do
      # Shows the existing blocked emails on initial page load
      expect(page).to have_field("Block emails from purchasing", with: "customer1@example.com\ncustomer2@example.com")

      # Unblocks the missing email and blocks all provided emails
      fill_in "Block emails from purchasing", with: "customer.2@example.com,,JOhN +1   @exAMPLE.com\n\n\ncustomer   2@ EXAMPLE.com,\nbob@  example.com"
      click_on "Update settings", match: :first
      wait_for_ajax
      expect(page).to have_alert(text: "Your account has been updated!")
      expect(page).to have_field("Block emails from purchasing", with: "customer2@example.com\njohn@example.com\nbob@example.com")
      expect(seller.blocked_customer_objects.active.email.pluck(:object_value)).to match_array(["customer2@example.com", "john@example.com", "bob@example.com"])

      # Does not allow saving invalid emails
      fill_in "Block emails from purchasing", with: "JOHN @example.com\ninvalid-email@example,john+test1@EXAMPLE.com\njane.doe@example.com\nbob..rocks@example.com\nfoo+thespammer@example.com"
      click_on "Update settings", match: :first
      wait_for_ajax
      expect(page).to have_alert(text: "The email invalid-email@example cannot be blocked as it is invalid.")
      expect(page).to have_field("Block emails from purchasing", with: "john@example.com\ninvalid-email@example\njanedoe@example.com\nbob..rocks@example.com\nfoo@example.com")
      expect(seller.blocked_customer_objects.active.email.pluck(:object_value)).to match_array(["customer2@example.com", "john@example.com", "bob@example.com"])

      # Unblocks all the previously blocked emails if saved with a blank value
      fill_in "Block emails from purchasing", with: ""
      click_on "Update settings", match: :first
      wait_for_ajax
      expect(page).to have_alert(text: "Your account has been updated!")
      expect(page).to have_field("Block emails from purchasing", with: "")
      expect(seller.blocked_customer_objects.active.email.count).to eq(0)

      refresh
      expect(page).to have_field("Block emails from purchasing", with: "")
    end
  end
end
