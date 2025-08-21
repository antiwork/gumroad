# frozen_string_literal: true

require "spec_helper"

describe("Password Settings Scenario", type: :system, js: true) do
  let(:compromised_password) { "password" }
  let(:not_compromised_password) { SecureRandom.hex(24) }

  before do
    login_as user
  end

  context "when logged in using social login provider" do
    let(:user) { create(:user, provider: :facebook) }

    before(:each) do
      login_as user
    end

    it "doesn't allow setting a new password with a value that was found in the password breaches" do
      visit settings_password_path

      expect(page).to_not have_field("Old password")

      within("form") do
        fill_in("Add password", with: compromised_password)
      end

      vcr_turned_on do
        VCR.use_cassette("Add Password-with a compromised password") do
          with_real_pwned_password_check do
            click_on("Change password")
            wait_for_ajax
          end
        end
      end

      expect(page).to have_alert(text: "New password has previously appeared in a data breach as per haveibeenpwned.com and should never be used. Please choose something harder to guess.")
    end

    it "allows setting a new password with a value that was not found in the password breaches" do
      visit settings_password_path

      expect(page).to_not have_field("Old password")

      within("form") do
        fill_in("Add password", with: not_compromised_password)
      end

      vcr_turned_on do
        VCR.use_cassette("Add Password-with a not compromised password") do
          with_real_pwned_password_check do
            click_on("Change password")
            wait_for_ajax
          end
        end
      end

      expect(page).to have_alert(text: "You have successfully changed your password.")
    end
  end

  context "when not logged in using social provider" do
    let(:user) { create(:user) }

    before(:each) do
      login_as user
    end

    it "validates the new password length" do
      visit settings_password_path

      expect do
        fill_in("Old password", with: user.password)
        fill_in("New password", with: "123")
        click_on("Change password")
        expect(page).to have_alert(text: "Your new password is too short.")
      end.to_not change { user.reload.encrypted_password }

      expect do
        fill_in("New password", with: "1234")
        click_on("Change password")
        expect(page).to have_alert(text: "You have successfully changed your password.")
      end.to change { user.reload.encrypted_password }

      expect do
        fill_in("Old password", with: "1234")
        fill_in("New password", with: "*" * 128)
        click_on("Change password")
        expect(page).to have_alert(text: "Your new password is too long.")
      end.to_not change { user.reload.encrypted_password }

      expect do
        fill_in("Old password", with: "1234")
        fill_in("New password", with: "*" * 127)
        click_on("Change password")
        expect(page).to have_alert(text: "You have successfully changed your password.")
      end.to change { user.reload.encrypted_password }
    end

    it "doesn't allow changing the password with a value that was found in the password breaches" do
      visit settings_password_path


      within("form") do
        fill_in("Old password", with: user.password)
        fill_in("New password", with: compromised_password)
      end

      vcr_turned_on do
        VCR.use_cassette("Add Password-with a compromised password") do
          with_real_pwned_password_check do
            click_on("Change password")
            wait_for_ajax
          end
        end
      end

      expect(page).to have_alert(text: "New password has previously appeared in a data breach as per haveibeenpwned.com and should never be used. Please choose something harder to guess.")
    end

    it "allows changing the password with a value that was not found in the password breaches" do
      visit settings_password_path


      within("form") do
        fill_in("Old password", with: user.password)
        fill_in("New password", with: not_compromised_password)
      end

      vcr_turned_on do
        VCR.use_cassette("Add Password-with a not compromised password") do
          with_real_pwned_password_check do
            click_on("Change password")
            wait_for_ajax
          end
        end
      end

      expect(page).to have_alert(text: "You have successfully changed your password.")
    end
  end
end
