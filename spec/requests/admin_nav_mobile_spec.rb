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
    expect(page).to_not have_link("Suspend users")
    expect(page).to_not have_link("Block emails")
  end
end
