# frozen_string_literal: true

require("spec_helper")

describe("Authentication Scenario", type: :system, js: true) do
  include FillInUserProfileHelpers

  before(:each) do
    create(:user)
  end

  describe("when user is not logged in") do
    it "prevents signing up with a compromised password" do
      visit("/signup")

      expect do
        vcr_turned_on do
          VCR.use_cassette("Signup-with a compromised password") do
            with_real_pwned_password_check do
              fill_in("Email", with: "user@test.com")
              fill_in("Password", with: "password")
              click_on("Create account")

              expect(page).to_not have_content("Dashboard")
              expect(page).to have_alert(text: "Password has previously appeared in a data breach as per haveibeenpwned.com and should never be used. Please choose something harder to guess.")
            end
          end
        end
      end.not_to change { User.count }
    end

    it "signs me up for the no-cost account" do
      visit("/signup")

      expect do
        with_real_pwned_password_check do
          fill_in("Email", with: "user@test.com")
          fill_in("Password", with: SecureRandom.hex(24))
          click_on("Create account")

          expect(page).to have_content("Dashboard")
        end
      end.to change { User.count }.by(1)
    end

    it "logs in with a non-compromised password" do
      visit("/")

      vcr_turned_on do
        VCR.use_cassette("Login-with non compromised password") do
          with_real_pwned_password_check do
            user = create(:user)

            fill_in("Email", with: user.email)
            fill_in("Password", with: user.password)
            click_on("Login")

            expect(page).to have_selector("h1", text: "Dashboard")
            expect(page).to_not have_alert
          end
        end
      end
    end

    it "logs in with a compromised password and displays a warning" do
      visit("/")

      vcr_turned_on do
        VCR.use_cassette("Login-with a compromised password") do
          with_real_pwned_password_check do
            user = create(:user_with_compromised_password, username: nil)

            fill_in("Email", with: user.email)
            fill_in("Password", with: user.password)
            click_on("Login")

            expect(page).to have_selector("h1", text: "Dashboard")
            expect(page).to have_alert(text: "Your password has previously appeared in a data breach as per haveibeenpwned.com and should never be used. We strongly recommend you change your password everywhere you have used it.")
          end
        end
      end
    end
  end

  describe("when user is logged in") do
    before(:each) do
      @user = create(:user)
      login_as(@user)
      visit "/dashboard"
      fill_in_profile
    end

    it("logs me out") do
      expect(page).to have_disclosure_button @user.reload.display_name
      toggle_disclosure @user.display_name
      click_on "Logout"
      expect(page).to(have_content("Log in"))
    end
  end

  describe("when user is logged in and has a social provider") do
    before do
      with_real_pwned_password_check do
        login_as(create(:user_with_compromised_password, provider: :facebook))
      end
    end

    it("doesn't show the old password field") do
      visit settings_password_path
      expect(page).to_not have_field("Old password")
      expect(page).to_not have_field("New password")
      expect(page).to have_field("Add password")
    end

    it "doesn't check whether the password is compromised or not" do
      expect(Pwned::Password).to_not receive(:new)

      visit("/dashboard")

      expect(page).to have_selector("h1", text: "Dashboard")
      expect(page).to_not have_alert
    end
  end

  describe "when a deleted user logs in" do
    it "does not undelete their account" do
      user = create(:user, deleted_at: 2.days.ago)
      visit("/")
      expect(page).to_not(have_selector("h1", text: "Welcome back to Gumroad."))
      fill_in("Email", with: user.email)
      fill_in("Password", with: user.password)
      click_on("Login")
      expect(page).to_not have_selector("h1", text: "Welcome back to Gumroad.")
      expect(user.reload.deleted?).to be(true)
    end
  end

  describe "when a suspended for TOS user logs in" do
    let(:product) { create(:product, user:) }
    let(:admin_user) { create(:user) }
    let(:user) { create(:named_user) }

    before do
      user.flag_for_tos_violation(author_id: admin_user.id, product_id: product.id)
      user.suspend_for_tos_violation(author_id: admin_user.id)
    end

    it "renders to the products page" do
      visit login_path

      fill_in("Email", with: user.email)
      fill_in("Password", with: user.password)
      click_on("Login")
      wait_for_ajax

      expect(page).to have_link("Products")
    end
  end
end
