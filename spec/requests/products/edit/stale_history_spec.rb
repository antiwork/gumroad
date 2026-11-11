# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit history restore", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, name: "Draft product", purchase_disabled_at: Time.current) }

  include_context "with switching account to user as admin for seller"

  it "loads the saved content when Back returns to the editor from another page" do
    visit edit_link_path(product.unique_permalink) + "/content"
    set_rich_text_editor_input(find("[aria-label='Content editor']"), to_text: "Saved content")
    save_change
    saved_page = product.reload.alive_rich_contents.sole

    click_on "Products"
    expect(page).to have_current_path(products_path)
    page.go_back
    expect(page).to have_current_path(edit_link_path(product.unique_permalink) + "/content")
    expect(find("[aria-label='Content editor']")).to have_text("Saved content")

    select_tab "Product"
    fill_in "Name", with: "Renamed", fill_options: { clear: :backspace }
    select_tab "Content"
    save_change

    product.reload
    expect(product.name).to eq("Renamed")
    expect(product.alive_rich_contents.sole).to eq(saved_page)
    expect(product.has_same_rich_content_for_all_variants?).to eq(true)
  end
end
