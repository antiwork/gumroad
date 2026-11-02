# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit tab history", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product_with_pdf_file, user: seller, name: "Saved name") }

  include_context "with switching account to user as admin for seller"

  it "keeps unsaved edits when Back and Forward move between tabs" do
    visit edit_link_path(product.unique_permalink)
    fill_in "Name", with: "Unsaved name", fill_options: { clear: :backspace }

    select_tab "Content"
    expect(page).to have_current_path(edit_link_path(product.unique_permalink) + "/content")

    page.go_back
    expect(page).to have_current_path(edit_link_path(product.unique_permalink))
    expect(page).to have_tab_button("Product", open: true)
    expect(page).to have_field("Name", with: "Unsaved name")

    page.go_forward
    expect(page).to have_current_path(edit_link_path(product.unique_permalink) + "/content")
    expect(page).to have_tab_button("Content", open: true)

    select_tab "Product"
    expect(page).to have_field("Name", with: "Unsaved name")
    expect(product.reload.name).to eq("Saved name")
  end

  it "leaves Back and Forward between the editor and other pages to Inertia" do
    visit edit_link_path(product.unique_permalink)
    select_tab "Content"
    click_on "Products"
    expect(page).to have_current_path(products_path)
    expect(page).to have_table_row({ "Name" => product.name })

    page.go_back
    expect(page).to have_current_path(edit_link_path(product.unique_permalink) + "/content")
    expect(page).to have_tab_button("Content", open: true)

    page.go_back
    expect(page).to have_current_path(edit_link_path(product.unique_permalink))
    expect(page).to have_tab_button("Product", open: true)

    page.go_forward
    expect(page).to have_current_path(edit_link_path(product.unique_permalink) + "/content")
    expect(page).to have_tab_button("Content", open: true)

    page.go_forward
    expect(page).to have_current_path(products_path)
    expect(page).to have_table_row({ "Name" => product.name })
  end

  it "keeps the current tab on Back while an image is still uploading" do
    visit edit_link_path(product.unique_permalink) + "/content"
    expect(page).to have_tab_button("Content", open: true)
    # Inertia saves a scroll position this way, and that drops React Router's index from the entry.
    page.execute_script("history.replaceState({ page: history.state.page }, '')")
    select_tab "Product"

    fixture_file = file_fixture("smilie.png")
    with_throttled_network(fixture_file, factor: 0.1) do
      attach_file fixture_file do
        click_on "Insert image"
      end
      expect(find("[aria-label='Description']")).to have_selector("figure [role='progressbar']")

      page.go_back
      expect(page).to have_alert(text: "Some images are still uploading, please wait...")
      expect(page).to have_current_path(edit_link_path(product.unique_permalink))
      expect(page).to have_tab_button("Product", open: true)
    end

    expect(find("[aria-label='Description']")).to_not have_selector("figure [role='progressbar']")
    page.go_back
    expect(page).to have_current_path(edit_link_path(product.unique_permalink) + "/content")
    expect(page).to have_tab_button("Content", open: true)
  end
end
