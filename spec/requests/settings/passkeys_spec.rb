# frozen_string_literal: true

require "spec_helper"

describe("Passkeys Settings Scenario", type: :system, js: true) do
  let(:seller) { create(:user) }

  before do
    Feature.activate_user(:passkeys, seller)
    login_as seller
  end

  it "shows the empty state when the seller has no passkeys" do
    visit settings_password_path

    within_section("Passkeys", section_element: :section) do
      expect(page).to have_text("Passkeys are an easier, more secure alternative to passwords")
      expect(page).to_not have_button("Rename")
    end
  end

  it "adds a passkey with the browser authenticator" do
    use_webauthn_driver
    visit settings_password_path
    register_virtual_authenticator!
    visit settings_password_path

    click_on "Add a passkey"

    expect(page).to have_alert(text: "Passkey added.")
    within_section("Passkeys", section_element: :section) do
      expect(page).to have_button("Remove")
    end
    expect(seller.webauthn_credentials.count).to eq(1)
  end

  it "lists the seller's passkeys" do
    create(:webauthn_credential, user: seller, nickname: "MacBook Pro")
    create(:webauthn_credential, user: seller, nickname: "iPhone 15")

    visit settings_password_path

    within_section("Passkeys", section_element: :section) do
      expect(page).to have_text("MacBook Pro")
      expect(page).to have_text("iPhone 15")
    end
  end

  it "renames a passkey" do
    create(:webauthn_credential, user: seller, nickname: "MacBook Pro")

    visit settings_password_path

    within_section("Passkeys", section_element: :section) do
      click_on "Rename"
      fill_in "Passkey name", with: "Work laptop"
      click_on "Save"

      expect(page).to have_text("Work laptop")
      expect(page).to_not have_text("MacBook Pro")
    end

    expect(seller.webauthn_credentials.sole.nickname).to eq("Work laptop")
  end

  it "disables saving a rename when the name is blank" do
    create(:webauthn_credential, user: seller, nickname: "MacBook Pro")

    visit settings_password_path

    within_section("Passkeys", section_element: :section) do
      click_on "Rename"
      fill_in "Passkey name", with: ""

      expect(page).to have_button("Save", disabled: true)
    end

    expect(seller.webauthn_credentials.sole.nickname).to eq("MacBook Pro")
  end

  it "removes a passkey after confirmation" do
    create(:webauthn_credential, user: seller, nickname: "MacBook Pro")

    visit settings_password_path

    within_section("Passkeys", section_element: :section) do
      click_on "Remove"
    end

    within_modal "Remove passkey" do
      click_on "Remove"
    end

    expect(page).to have_alert(text: "Passkey removed.")
    expect(seller.webauthn_credentials).to be_empty
  end

  context "when the passkeys feature is disabled" do
    before { Feature.deactivate_user(:passkeys, seller) }

    it "does not show the passkeys section" do
      visit settings_password_path

      expect(page).to have_text("Change password")
      expect(page).to_not have_text("Passkeys are an easier, more secure alternative to passwords")
    end
  end
end
