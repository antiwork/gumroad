# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "tab navigation on products page" do
  it "shows the correct tabs" do
    create(:product, user: seller)

    visit url

    within find("[role=tablist]") do
      expect(find(:tab_button, "All products")[:href]).to eq(products_url(host: DOMAIN))
      expect(find(:tab_button, "Affiliated")[:href]).to eq(products_affiliated_index_url(host: DOMAIN))
      expect(find(:tab_button, "Collabs")[:href]).to eq(products_collabs_url(host: DOMAIN))
      expect(page).not_to have_tab_button("Archived")
    end
  end

  it "conditionally shows additional tabs" do
    create(:product, user: seller, archived: true)

    visit(products_path)

    within find("[role=tablist]") do
      expect(find(:tab_button, "Archived")[:href]).to eq(products_archived_index_url(host: DOMAIN))
    end
  end
end
