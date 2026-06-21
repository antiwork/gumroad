# frozen_string_literal: true

require "spec_helper"

describe("Passkey Login Scenario", type: :system, js: true) do
  let(:user) { create(:user) }

  before do
    use_webauthn_driver
    Feature.activate(:passkeys)
  end

  it "registers a passkey, then signs in with it and bypasses the 2FA challenge" do
    user.update!(two_factor_authentication_enabled: true)

    login_as user
    visit settings_password_path
    register_virtual_authenticator!
    visit settings_password_path
    click_on "Add a passkey"
    expect(page).to have_alert(text: "Passkey added.")
    expect(user.webauthn_credentials.count).to eq(1)

    logout(:user)
    visit login_path

    # Conditional UI arms a discoverable passkey request on load; the virtual
    # authenticator auto-consents, signing the user in and bypassing 2FA without
    # the fallback "Log in with a passkey" button.
    expect(page).to have_current_path(dashboard_path, wait: 15)
    expect(user.webauthn_credentials.sole.last_used_at).to be_present
  end
end
