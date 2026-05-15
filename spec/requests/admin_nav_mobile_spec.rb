# frozen_string_literal: true

require "spec_helper"

describe("Admin - Nav - Mobile", :js, :mobile_view, type: :system) do
  let(:admin) { create(:admin_user) }

  before do
    login_as admin
  end

  it "auto closes the menu when navigating to a different page" do
    visit admin_suspend_users_path

    click_on "Toggle navigation"
    expect(page).to have_link("Suspend users")
    expect(page).to have_link("Block emails")

    click_on "Block emails"
    expect(page).to have_current_path(admin_blocked_emails_path)
    expect(page).to have_no_link("Suspend users", wait: 10)
    expect(page).to have_no_link("Block emails", wait: 10)
  end
end
