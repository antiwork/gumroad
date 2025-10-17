# frozen_string_literal: true

require("spec_helper")

describe("Password Reset", type: :system, js: true) do
  include FillInUserProfileHelpers

  before(:each) do
    @user = create(:user)
    @original_encrypted_password = @user.encrypted_password
    @token = @user.send(:set_reset_password_token)
  end

  it "resets the password if it is not compromised" do
    visit edit_user_password_path(@user, reset_password_token: @token)

    vcr_turned_on do
      VCR.use_cassette("Password reset - with non compromised password") do
        with_real_pwned_password_check do
          new_password = SecureRandom.hex(15)
          fill_in("Enter a new password", with: new_password)
          fill_in("Enter same password to confirm", with: new_password)
          click_on("Reset")

          expect(page).to have_text("Your password has been reset")
          expect(@user.reload.encrypted_password).not_to eq(@original_encrypted_password)
        end
      end
    end
  end

  it "does not reset the password if it is compromised" do
    visit edit_user_password_path(@user, reset_password_token: @token)

    vcr_turned_on do
      VCR.use_cassette("Password reset - with compromised password") do
        with_real_pwned_password_check do
          fill_in("Enter a new password", with: "password")
          fill_in("Enter same password to confirm", with: "password")
          click_on("Reset")

          expect(page).to have_text("Password has previously appeared in a data breach")
          expect(@user.reload.encrypted_password).to eq(@original_encrypted_password)
        end
      end
    end
  end
end
