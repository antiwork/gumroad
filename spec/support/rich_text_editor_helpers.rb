# frozen_string_literal: true

module RichTextEditorHelpers
  def set_rich_text_editor_input(node, to_text:)
    node.native.clear
    node.base.send_keys(to_text)
  end

  def rich_text_editor_select_all(node)
    node.native.send_keys(ctrl_key, "a")
  end

  def drag_file_embed_to(name:, to:)
    file_embed = find_embed(name:)
    file_embed.drag_to(to)
  end

  def wait_for_image_to_finish_uploading
    expect(page).to_not have_selector("img[src*='blob:']")
  end

  def toggle_file_group(name)
    find("[role=treeitem] h4", text: name, match: :first).click
  end

  def find_file_group(name)
    find("[role=treeitem] h4", text: name, match: :first).ancestor("[role=treeitem]")
  end

  def within_file_group(name, &block)
    within find_file_group(name), &block
  end

  def have_file_group(name)
    have_selector("[role=treeitem] h4", text: name)
  end

  def find_input_embed(label_or_text)
    content_editor = find("[aria-label='Content editor']")
    if label_or_text == "Upload files"
      content_editor.find(:button, "Upload files", match: :first).ancestor("[data-input-embed]")
    else
      content_editor.find(:field, "Title", with: label_or_text, match: :first).ancestor("[data-input-embed]")
    end
  end

  def ctrl_key
    page.driver.browser.capabilities.platform_name.include?("mac") ? :command : :control
  end
end
