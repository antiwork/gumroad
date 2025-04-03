# frozen_string_literal: true

module EmailHelpers
  def upload_attachment(name, wait_until_uploaded: true)
    attach_file("Attach files", file_fixture(name), visible: false)
    expect(page).to have_button("Save", disabled: false) if wait_until_uploaded
  end

  def find_attachment(name)
    within "[aria-label='Files']" do
      find("[role=listitem] h4", text: name, exact_text: true).ancestor("[role=listitem]")
    end
  end

  def have_attachment(name:, count: nil)
    options = { text: name, exact_text: true, count: }.compact
    have_selector("[aria-label='Files'] [role=listitem] h4", **options)
  end
end
