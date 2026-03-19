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
            expect(page).to have_alert(text: "New password has previously appeared in a data breach as per haveibeenpwned.com and should never be used. Please choose something harder to guess.")
          end
        end
      end
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
            expect(page).to have_alert(text: "You have successfully changed your password.")
          end
        end
      end
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
            expect(page).to have_alert(
              text: "New password has previously appeared in a data breach as per haveibeenpwned.com and should never be used. Please choose something harder to guess.",
            )
          end
        end
      end
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
            expect(page).to have_alert(text: "You have successfully changed your password.")
          end
        end
      end
    end
  end

  describe "two-factor authentication section" do
    let(:user) { create(:user) }

    context "when feature flag is active" do
      before do
        Feature.activate(:authenticator_2fa)
      end

      it "displays authenticator app status" do
        visit settings_password_path

        expect(page).to have_text("Two-factor authentication")
        expect(page).to have_text("Authenticator app")
        expect(page).to have_button("Set up")
      end

      it "allows setting up and then removing the authenticator app" do
        visit settings_password_path

        click_on("Set up")
        expect(page).to have_text("Scan this QR code")
        expect(page).to have_selector("[data-testid='qr-code']")

        credential = user.reload.totp_credential
        expect(credential).to be_present
        expect(credential).not_to be_confirmed

        fill_in("Enter the code from your authenticator app", with: credential.otp_code)
        click_on("Verify")

        expect(page).to have_text("Save these codes")
        expect(credential.reload).to be_confirmed

        click_on("Done")
        expect(page).to have_button("Remove")

        click_on("Remove")
        expect(page).to have_button("Set up")
        expect(user.reload.totp_credential).to be_nil
      end

      context "when authenticator app is enabled" do
        before do
          create(:totp_credential, :with_recovery_codes, user:)
        end

        it "allows regenerating recovery codes" do
          visit settings_password_path

          click_on("Regenerate recovery codes")

          expect(page).to have_text("Save these codes")
          expect(page).to have_button("Copy all")
          expect(page).to have_button("Download")

          click_on("Done")
          expect(page).not_to have_text("Save these codes")
        end
      end
    end

    context "when feature flag is not active" do
      it "does not display the two-factor authentication section" do
        visit settings_password_path

        expect(page).not_to have_text("Two-factor authentication")
        expect(page).not_to have_text("Authenticator app")
      end
    end
  end
end
