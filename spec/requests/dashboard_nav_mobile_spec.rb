# frozen_string_literal: true

require "spec_helper"

describe("Dashboard - Nav - Mobile", :js, :mobile_view, type: :system) do
  let(:user) { create(:named_seller) }

  before do
    login_as user
  end

  it "auto closes the menu when navigating to a different page" do
    visit dashboard_path

    click_on "Toggle navigation"
    expect(page).to have_link("Products")
    expect(page).to have_link("Analytics")

    click_on "Products"
    expect(page).to_not have_link("Products")
    expect(page).to_not have_link("Analytics")
  end
end
