# frozen_string_literal: true

require "spec_helper"

describe "Select action buttons", type: :system, js: true do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller, name: "Example product") }

  before { login_as(seller) }

  [:enter, " "].each do |key|
    it "clears a product category with #{key.inspect} without submitting the form" do
      product.update!(taxonomy: Taxonomy.find_by!(slug: "design"))
      visit edit_link_path(product.unique_permalink) + "/share"

      within :fieldset, "Category" do
        find_button("Clear value").send_keys(key)
        expect(page).not_to have_button("Clear value")
        expect(page).to have_text("Begin typing to select a category")
      end
      expect(page).to have_current_path(edit_link_path(product.unique_permalink) + "/share")
      save_change
      expect(product.reload.taxonomy_id).to be_nil
    end

    it "removes a product tag with #{key.inspect} without opening the menu" do
      product.tags << create(:tag, name: "example")
      visit edit_link_path(product.unique_permalink) + "/share"

      within :fieldset, "Tags" do
        find_button("example", exact: true).send_keys(key)
        expect(page).not_to have_button("example", exact: true)
        expect(page).not_to have_selector('[role="option"]')
      end
      save_change
      expect(product.reload.tags).to be_empty
    end
  end

  it "preserves selected products when Enter is pressed in a discount name" do
    visit checkout_discounts_path
    click_on "New discount"
    select_combo_box_option product.name, from: "Products"
    fill_in "Name", with: "Keyboard discount"
    find_field("Name").send_keys(:enter)

    within :fieldset, "Products" do
      expect(page).to have_button(product.name, exact: true)
    end
  end
end
