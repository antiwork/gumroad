# frozen_string_literal: true

module ProductEditPageHelpers
  def save_change(expect_alert: true, expect_message: "Changes saved!")
    click_on "Save changes"

    # A save that removes existing versions/tiers/durations or content pages
    # first shows a summary confirmation modal (rendered synchronously by the
    # editor, before any request goes out). Confirm it so specs exercising
    # deletions proceed; saves that don't delete anything never show it.
    if page.has_text?("Save and delete content?", wait: 1)
      within_modal "Save and delete content?" do
        click_on "Yes, save and delete"
      end
    end

    wait_for_ajax

    if expect_alert
      expect(page).to have_alert(text: expect_message)
    end

    expect(page).to have_button "Save changes"
  end
end
