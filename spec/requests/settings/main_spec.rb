# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Main Settings Scenario", type: :system, js: true) do
  let(:user) { create(:user, name: "Gum") }

  before do
    login_as user
  end

  describe "sub navigation" do
    it "displays main, profile, payments, password, and advanced sections" do
      visit settings_main_path

      expect(page).to have_tab_button "Settings"
      expect(page).to have_tab_button "Profile"
      expect(page).to have_tab_button "Payments"
      expect(page).to have_tab_button "Password"
      expect(page).to have_tab_button "Advanced"
    end
  end

  context "when email is present" do
    it "allows user to update settings" do
      visit settings_main_path
      new_email = "k@gumroad.com"
      within_section "User details", section_element: :section do
        fill_in("Email", with: new_email)
      end
      click_on("Update settings")
      wait_for_ajax

      expect(page).to have_alert(text: "Your account has been updated!")
      expect(user.reload.unconfirmed_email).to eq new_email
    end
  end

  context "when email is empty" do
    before do
      user.email = nil
      user.save(validate: false)
    end

    it "shows an error flash message on save" do
      visit settings_main_path
      click_on("Update settings")

      expect(page).to have_alert(text: "Please enter an email address!")
    end
  end

  describe "Unconfirmed email" do
    context "when email is verified" do
      it "doesn't show resend link" do
        visit settings_main_path

        within_section "User details", section_element: :section do
          expect(find_field("Email").value).to eq user.email
        end
        expect(page).to_not have_link("Resend confirmation?")
      end
    end

    context "when email is not verified" do
      before do
        user.update!(email: "n00b@gumroad.com")
      end

      it "allows resending email confirmation" do
        visit settings_main_path

        within_section "User details", section_element: :section do
          expect(find_field("Email").value).to eq "n00b@gumroad.com"
        end
        expect(page).to have_text("This email address has not been confirmed yet. Resend confirmation?")
        click_on "Resend confirmation?"

        wait_for_ajax
        expect(page).to have_alert(text: "Confirmation email resent!")
        expect(page).to_not have_link("Resend confirmation?")
      end
    end
  end

  context "when logged user has role admin" do
    let(:seller) { create(:named_seller) }

    include_context "with switching account to user as admin for seller"

    it "disables the form" do
      visit settings_main_path
      expect(page).not_to have_link("Password")
      expect(page).not_to have_button("Update settings")
      expect(page).not_to have_selector(".js-invalidate-active-sessions-trigger", text: "Sign out from all active sessions")
    end
  end

  describe "purchasing power parity" do
    it "allows the user to update the settings" do
      visit settings_main_path

      expect(page).to have_unchecked_field("Enable purchasing power parity")
      check "Enable purchasing power parity"
      fill_in "Maximum PPP discount", with: "50"
      check "Apply only if the customer is currently located in the country of their payment method"
      click_on "Update settings"
      expect(page).to have_alert(text: "Your account has been updated!")
      user.reload
      expect(user.purchasing_power_parity_enabled).to eq(true)
      expect(user.purchasing_power_parity_limit).to eq(50)
      expect(user.purchasing_power_parity_payment_verification_disabled).to eq(false)


      visit settings_main_path
      expect(page).to have_checked_field("Enable purchasing power parity")
      fill_in "Maximum PPP discount", with: ""
      uncheck "Apply only if the customer is currently located in the country of their payment method"
      uncheck "Enable purchasing power parity"
      expect(page).to_not have_field("Maximum PPP discount")
      expect(page).to_not have_field("Apply only if the customer is currently located in the country of their payment method")
      click_on "Update settings"
      expect(page).to have_alert(text: "Your account has been updated!")
      user.reload
      expect(user.purchasing_power_parity_enabled).to eq(false)
      expect(user.purchasing_power_parity_limit).to eq(nil)
      expect(user.purchasing_power_parity_payment_verification_disabled).to eq(true)

      visit settings_main_path
      expect(page).to have_unchecked_field("Enable purchasing power parity")
    end

    describe "excluding products" do
      before do
        @product_1 = create(:product, user:, name: "Product 1")
        @product_2 = create(:product, user:, name: "Product 2")

        user.update(purchasing_power_parity_enabled: true)
      end

      it "allows the user to exclude certain products" do
        visit settings_main_path

        select_combo_box_option "Product 2", from: "Products to exclude"

        within_fieldset "Products to exclude" do
          expect(page).to have_button("Product 2")
        end

        click_on "Update settings"
        wait_for_ajax

        expect(page).to have_alert(text: "Your account has been updated!")
        user.reload

        expect(user.purchasing_power_parity_excluded_product_external_ids).to eq([@product_2.external_id])
        expect(@product_1.reload.purchasing_power_parity_enabled?).to eq(true)
        expect(@product_2.reload.purchasing_power_parity_enabled?).to eq(false)
      end

      it "allows the user to exclude all products" do
        visit settings_main_path

        check "All products", unchecked: true

        within_fieldset "Products to exclude" do
          expect(page).to have_button("Product 1")
          expect(page).to have_button("Product 2")
        end

        click_on "Update settings"
        wait_for_ajax
        user.reload

        expect(user.purchasing_power_parity_excluded_product_external_ids).to eq([@product_1.external_id, @product_2.external_id])
        expect(@product_1.reload.purchasing_power_parity_enabled?).to eq(false)
        expect(@product_2.reload.purchasing_power_parity_enabled?).to eq(false)
      end

      it "allows the user to remove all excluded products" do
        @product_1.update(purchasing_power_parity_disabled: true)
        @product_2.update(purchasing_power_parity_disabled: true)

        visit settings_main_path

        uncheck "All products", checked: true

        within_fieldset "Products to exclude" do
          expect(page).to_not have_button("Product 1")
          expect(page).to_not have_button("Product 2")
        end

        click_on "Update settings"
        wait_for_ajax
        user.reload

        expect(user.purchasing_power_parity_excluded_product_external_ids).to eq([])
        expect(@product_1.reload.purchasing_power_parity_enabled?).to eq(true)
        expect(@product_2.reload.purchasing_power_parity_enabled?).to eq(true)
      end
    end
  end

  it "allows the user to disable review notifications" do
    visit settings_main_path
    uncheck "Reviews", checked: true
    click_on "Update settings"
    expect(page).to have_alert(text: "Your account has been updated!")
    expect(user.reload.disable_reviews_email).to eq(true)

    visit settings_main_path
    check "Reviews", unchecked: true
    click_on "Update settings"
    expect(page).to have_alert(text: "Your account has been updated!")
    expect(user.reload.disable_reviews_email).to eq(false)
  end

  it "allows the user to toggle showing NSFW products" do
    visit settings_main_path

    expect(user.show_nsfw_products).to eq(false)
    expect(page).to have_unchecked_field("Show adult content in recommendations and search results")

    check "Show adult content in recommendations and search results"
    click_on "Update settings"

    expect(page).to have_alert(text: "Your account has been updated!")
    expect(user.reload.show_nsfw_products).to eq(true)

    uncheck "Show adult content in recommendations and search results"
    click_on "Update settings"
    wait_for_ajax

    expect(page).to have_alert(text: "Your account has been updated!")
    expect(user.reload.show_nsfw_products).to eq(false)
  end

  describe "Refund policy" do
    context "when the refund policy is enabled" do
      before do
        user.update!(refund_policy_enabled: true)
        user.refund_policy.update!(max_refund_period_in_days: 0)
      end

      it "allows the user to update the refund policy" do
        visit settings_main_path
        expect(page).to have_field("Add a fine print to your refund policy", disabled: true)

        select "30-day money back guarantee", from: "Refund period"
        check "Add a fine print to your refund policy"
        fill_in "Fine print", with: "This is a sample fine print"

        click_on "Update settings"
        wait_for_ajax

        expect(page).to have_alert(text: "Your account has been updated!")

        refund_policy = user.refund_policy.reload
        expect(refund_policy.max_refund_period_in_days).to eq(30)
        expect(refund_policy.fine_print).to eq("This is a sample fine print")
      end
    end

    context "when the refund policy is disabled" do
      it "does not allow the user to update the refund policy" do
        visit settings_main_path
        expect(page).to_not have_field("Refund policy")
      end
    end
  end
end
