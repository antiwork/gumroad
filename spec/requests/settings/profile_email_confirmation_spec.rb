# frozen_string_literal: true

require "spec_helper"

describe "Profile settings email confirmation", type: :system, js: true do
  let(:seller) { create(:user, email: "seller@example.com", username: "unconfirmedseller", confirmed_at: nil) }

  it "warns unconfirmed sellers before they edit an unsavable profile" do
    login_as(seller)
    visit "/profile"

    expect(page).to have_alert(text: "Confirm your email address (seller@example.com) before you can save changes to your profile.")
    expect(page).to have_field("Name", disabled: true)
    click_button "Resend confirmation email"
    expect(page).to have_text("Confirmation email sent!")
  end

  it "leaves a confirmed seller's editor untouched" do
    login_as(create(:user, email: "confirmed@example.com", username: "confirmedseller"))
    visit "/profile"

    expect(page).to have_field("Name", disabled: false)
    expect(page).not_to have_text("before you can save changes to your profile")
  end

  it "gives the right refresh instruction when confirmation finishes in another tab" do
    login_as(seller)
    visit "/profile"
    seller.confirm

    click_button "Resend confirmation email"

    expect(page).to have_alert(text: "Your email address is already confirmed — refresh the page to continue.")
  end
end
