# frozen_string_literal: true

require "spec_helper"

describe "Product edit version history", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, name: "Clicker") }
  let!(:first_build) { create(:product_build, product:, number: 1, byte_size: 2.megabytes) }
  let!(:second_build) { create(:product_build, product:, number: 2, byte_size: 3.megabytes) }

  def version_row(number) = find("[role=listitem][aria-label='Version #{number}']")

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
    expect(page).to have_text("Web app, version 2")

    click_on "History"
    within find("[role=dialog]", text: "Version history") do
      within(version_row(2)) { expect(page).to have_text("Live").and have_text("Buyers get this version") }
      click_on "Actions for version 1"
    end
    click_on "Make live"
    within_modal "Make version 1 live?" do
      click_on "Make version 1 live"
    end

    expect(page).to have_text("Web app, version 1")
    expect(page).not_to have_text("Web app, version 2")
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
    click_on "Open version history"
    within find("[role=dialog]", text: "Version history") do
      within(version_row(1)) { click_on "Make live" }
    end
    within_modal "Make version 1 live?" do
      click_on "Make version 1 live"
    end

    expect(page).to have_text("Web app, version 1")
    expect(page).not_to have_text("Your web app is not in this product's content yet.")
    expect(first.reload.status).to eq("live")
  end

  it "adds the live version back to the content after the seller removed its row" do
    second_build.product_file.mark_deleted!
    product.alive_rich_contents.each { _1.update!(description: []) }

    visit edit_link_path(product.unique_permalink)
    select_tab "Content"
    expect(page).to have_text("Your web app is not in this product's content yet.")
    expect(page).not_to have_text("Web app, version 2")
    click_on "Open version history"
    within find("[role=dialog]", text: "Version history") do
      within(version_row(2)) { click_on "Add to content" }
    end
    within_modal "Add version 2 back to the content?" do
      click_on "Add to content"
    end

    expect(page).to have_text("Web app, version 2")
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
    expect(page).to have_button("Open version history")
  end

  it "uploads a zip from the editor as the first version, then makes it live" do
    new_product = create(:product, user: seller, name: "Course")
    zip_path = Rails.root.join("tmp", "version-history-#{SecureRandom.hex(4)}.zip")
    Zip::OutputStream.open(zip_path) do |zip|
      zip.put_next_entry("index.html")
      zip.write("<!doctype html><title>Course</title><p>Lesson 1</p>")
    end

    visit "#{edit_link_path(new_product.unique_permalink)}/content"
    select_disclosure "Upload files"
    click_on "Web app"
    within find("[role=dialog]", text: "Add a web app") do
      attach_file("Web app zip", zip_path, visible: false)
      within(version_row(1)) do
        expect(page).to have_text("Not live yet")
        click_on "Make live"
      end
    end
    within_modal "Make version 1 live?" do
      click_on "Make version 1 live"
    end

    expect(page).to have_text("Web app, version 1")
    expect(new_product.product_builds.sole.status).to eq("live")
    expect(new_product.alive_rich_contents.sole.embedded_product_file_ids_in_order).to eq([new_product.product_builds.sole.product_file_id])
  ensure
    FileUtils.rm_f(zip_path)
  end

  it "has no version history while the player is off for the seller" do
    Feature.deactivate_user(:product_build_player, seller)

    visit edit_link_path(product.unique_permalink)
    select_tab "Content"

    expect(page).to have_text("Web app, version 2")
    expect(page).not_to have_button("History")
  end
end
