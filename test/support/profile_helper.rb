# frozen_string_literal: true

# Helper method to complete user profile fields
# Used in auth specs where dashboard and logout option are visible only after profile is filled in
module FillInUserProfileHelpers
  def fill_in_profile
    visit settings_profile_path

    fill_in("Username", with: "gumbo")
    fill_in("Name", with: "Edgar Gumstein")

    click_on("Update settings")
  end

  def submit_follow_form(with: nil)
    fill_in("Your email address", with:) if with.present?
    click_on("Subscribe")
  end
end
