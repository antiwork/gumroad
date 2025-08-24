# frozen_string_literal: true

require "spec_helper"

describe("Product Edit Save Shortcut", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller, name: "Original Name", price_cents: 1000) }

  include_context "with switching account to user as admin for seller"

  it "toggles aria-keyshortcuts on the Save button based on PRODUCT_EDITOR_SAVE_SHORTCUT" do
    visit edit_link_path(product.unique_permalink)

    if ENV["PRODUCT_EDITOR_SAVE_SHORTCUT"] == "false"
      expect(page).not_to have_selector("button[aria-keyshortcuts]", text: "Save changes")
    else
      expect(page).to have_selector("button[aria-keyshortcuts='Control+S Meta+S']", text: "Save changes")
    end
  end

  it "saves via Ctrl+S when not typing in a text field" do
    visit edit_link_path(product.unique_permalink)

    new_name = "Saved via shortcut"
    fill_in("Name", with: new_name)

    # Ensure focus is not in a text input so the shortcut triggers save
    unfocus

    find("body").send_keys([:control, "s"]) # Cmd on mac, Ctrl on others; handler supports both

    wait_for_ajax
    expect(page).to have_alert(text: "Changes saved!")
    expect(product.reload.name).to eq(new_name)
  end

  it "does not save via Ctrl+S while focus is in a text input" do
    visit edit_link_path(product.unique_permalink)

    not_saved_name = "Typing but not saved"
    fill_in("Name", with: not_saved_name)

    # Keep focus in the input and press Ctrl+S
    find_field("Name").send_keys([:control, "s"]) # preventDefault but do not save

    # Give the app a moment in case any async handlers fire
    sleep 0.5

    # Should NOT have persisted the change
    expect(product.reload.name).not_to eq(not_saved_name)
  end

  it "does not save via Ctrl+S while focus is in a contenteditable area" do
    visit edit_link_path(product.unique_permalink)

    tentative_name = "Should not save while editing rich text"
    fill_in("Name", with: tentative_name)

    # Focus the rich text editor (contenteditable)
    rich_text = find("[contenteditable='true']", match: :first)
    rich_text.click

    # Press Ctrl+S while editor is focused; handler should ignore save
    rich_text.send_keys([:control, "s"]) # preventDefault but do not save

    sleep 0.5
    expect(product.reload.name).not_to eq(tentative_name)
  end
end
