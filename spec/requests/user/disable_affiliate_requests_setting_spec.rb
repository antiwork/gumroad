# frozen_string_literal: true

require "spec_helper"

describe "Disable affiliate requests setting", type: :system, js: true do
  let(:user) { create(:named_user) }

  before do
    login_as(user)
  end

  it "allows user to toggle the prevent being added as affiliate setting" do
    visit settings_main_path

    within_section "Affiliates", section_element: :section do
      expect(page).to have_text("Prevent others from adding me as an affiliate")
      expect(page).to have_text("When enabled, other users cannot add you as an affiliate or request to become your affiliate.")

      expect(page).to have_field("Prevent others from adding me as an affiliate", checked: false)

      check "Prevent others from adding me as an affiliate"
    end

    click_on "Update settings"
    wait_for_ajax
    expect(page).to have_alert(text: "Your account has been updated!")

    expect(user.reload.disable_affiliate_requests?).to eq(true)

    refresh
    within_section "Affiliates", section_element: :section do
      expect(page).to have_field("Prevent others from adding me as an affiliate", checked: true)
    end

    within_section "Affiliates", section_element: :section do
      uncheck "Prevent others from adding me as an affiliate"
    end

    click_on "Update settings"
    wait_for_ajax
    expect(page).to have_alert(text: "Your account has been updated!")

    expect(user.reload.disable_affiliate_requests?).to eq(false)
  end

  it "shows the affiliates section in the settings page" do
    visit settings_main_path

    expect(page).to have_section("Affiliates")
    within_section "Affiliates", section_element: :section do
      expect(page).to have_text("Prevent others from adding me as an affiliate")
      expect(page).to have_text("When enabled, other users cannot add you as an affiliate or request to become your affiliate.")
    end
  end
end
