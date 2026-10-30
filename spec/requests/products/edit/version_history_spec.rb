# frozen_string_literal: true

require "spec_helper"

describe "Product edit version history", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, name: "Clicker") }
  let!(:first_build) { create(:product_build, product:, number: 1, byte_size: 2.megabytes) }
  let!(:second_build) { create(:product_build, product:, number: 2, byte_size: 3.megabytes) }

  before do
    create(:rich_content, entity: product, description: [])
    first_build.promote!
    second_build.promote!
    Feature.activate_user(:product_build_player, seller)
    login_as(seller)
  end

  it "lists the builds and makes an earlier one live, saving the seller's unsaved edits first" do
    visit edit_link_path(product.unique_permalink)
    fill_in "Name", with: "Clicker 2", fill_options: { clear: :backspace }
    select_tab "Content"
    expect(page).to have_text("Web build v2")

    click_on "History"
    within find("[role=dialog]", text: "Version history") do
      within("section", text: "Buyers get this version") { expect(page).to have_text("Version 2") }
      click_on "Actions for version 1"
    end
    click_on "Make live"
    within_modal "Make version 1 live?" do
      click_on "Make version 1 live"
    end

    expect(page).to have_text("Web build v1")
    expect(page).not_to have_text("Web build v2")
    expect(first_build.reload.status).to eq("live")
    expect(second_build.reload.status).to eq("superseded")
    expect(product.reload.name).to eq("Clicker 2")
  end

  it "offers the history from the Content tab when no version has been made live yet" do
    new_product = create(:product, user: seller, name: "Fresh game")
    create(:rich_content, entity: new_product, description: [])
    first = create(:product_build, product: new_product, number: 1)

    visit edit_link_path(new_product.unique_permalink)
    select_tab "Content"
    expect(page).to have_text("Your web app is not in this product's content yet.")
    click_on "History"
    within find("[role=dialog]", text: "Version history") do
      within("section", text: "Ready to go live") { click_on "Make live" }
    end
    within_modal "Make version 1 live?" do
      click_on "Make version 1 live"
    end

    expect(page).to have_text("Web build v1")
    expect(page).not_to have_text("Your web app is not in this product's content yet.")
    expect(first.reload.status).to eq("live")
  end

  it "adds the live version back to the content after the seller removed its row" do
    second_build.product_file.mark_deleted!
    product.alive_rich_contents.each { _1.update!(description: []) }

    visit edit_link_path(product.unique_permalink)
    select_tab "Content"
    expect(page).to have_text("Your web app is not in this product's content yet.")
    expect(page).not_to have_text("Web build v2")
    click_on "History"
    within find("[role=dialog]", text: "Version history") do
      within("section", text: "Buyers get this version") { click_on "Add to content" }
    end
    within_modal "Add version 2 back to the content?" do
      click_on "Add to content"
    end

    expect(page).to have_text("Web build v2")
    expect(page).not_to have_text("Your web app is not in this product's content yet.")
  end

  it "offers the history as soon as the seller deletes the live build's row, before saving" do
    visit edit_link_path(product.unique_permalink)
    select_tab "Content"
    expect(page).not_to have_text("Your web app is not in this product's content yet.")

    within find_embed(name: "Clicker build 2.zip").hover do
      select_disclosure "Actions" do
        click_on "Delete"
      end
    end

    expect(page).to have_text("Your web app is not in this product's content yet.")
    expect(page).to have_button("History")
  end

  it "has no version history while the player is off for the seller" do
    Feature.deactivate_user(:product_build_player, seller)

    visit edit_link_path(product.unique_permalink)
    select_tab "Content"

    expect(page).to have_text("Web build v2")
    expect(page).not_to have_button("History")
  end
end
