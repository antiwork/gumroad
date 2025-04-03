# frozen_string_literal: true

# Helper method to upload post files
# Used in posts and workflow specs
module PostHelpers
  def upload_post_file(file_name)
    attach_post_file file_name
    wait_for_file_upload_to_finish file_name
  end

  def attach_post_file(file_name)
    page.attach_file(file_fixture(file_name)) do
      click_button "Attach files"
    end
  end

  def wait_for_file_upload_to_finish(file_name)
    file_display_name = File.basename(file_name, ".*") # remove the extension if any
    expect(page).to have_selector ".file-row-container.complete", text: file_display_name
  end
end
