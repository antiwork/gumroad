# frozen_string_literal: true

module ProductEditPageHelpers
  def save_change(expect_alert: true, expect_message: "Changes saved!")
    click_on "Save changes"
    wait_for_ajax

    if expect_alert
      expect(page).to have_alert(text: expect_message)
    end

    expect(page).to have_button "Save changes"
  end
end
