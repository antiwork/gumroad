# frozen_string_literal: true

require "spec_helper"

describe "Profile settings email confirmation", type: :system, js: true do
  let(:seller) { create(:user, email: "seller@example.com", username: "unconfirmedseller", confirmed_at: nil) }

  before do
    login_as(seller)
  end

  it "warns unconfirmed sellers before they edit an unsavable profile" do
    visit "/profile"

    expect(page).to have_alert(text: "Confirm your email address (seller@example.com) before you can save changes to your profile.")
    expect(page).to have_button("Update profile", disabled: true)
    expect(page).to have_field("Name", disabled: true)
    expect(page).to have_button("Resend confirmation email")
  end
end
