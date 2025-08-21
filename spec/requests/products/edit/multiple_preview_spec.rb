# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

def upload_image
  click_on "Upload images or videos"
  page.attach_file(Rails.root.join("spec", "support", "fixtures", "smaller.png")) do
    select_tab "Computer files"
  end
end

describe("Product edit multiple-preview Scenario", type: :system, js: true) do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }

  include_context "with switching account to user as admin for seller"

  it "uploads a preview image" do
    visit(edit_link_path(product))
    within_section "Cover", section_element: :section do
      upload_image
      img = first("img")
      expect(img.native.css_value("max-width")).to eq("100%")
      find("button[role='tab']").hover
      expect(page).to have_selector(".remove-button[aria-label='Remove cover']")
    end
  end

  it "uploads an image via URL" do
    visit(edit_link_path(product))
    within_section "Cover", section_element: :section do
      click_on "Upload images or videos"
      select_tab "External link"
      fill_in placeholder: "https://", with: "https://picsum.photos/200/300"
      click_on "Upload"
      img = first("img")
      expect(img.native.css_value("max-width")).to eq("100%")
      find("button[role='tab']").hover
      expect(page).to have_selector(".remove-button[aria-label='Remove cover']")
    end
  end

  it "uploads an image as a second preview" do
    create(:asset_preview, link: product)
    visit(edit_link_path(product))
    expect(page).to have_selector("img")
    expect do
      select_disclosure "Add cover" do
        upload_image
        expect(page).to have_selector("[role='progressbar']")
      end
      wait_for_ajax
    end.to change { product.reload.asset_previews.alive.count }.by(1)
  end

  it "fails with informative error for too many previews" do
    Link::MAX_PREVIEW_COUNT.times { create(:asset_preview, link: product) }
    visit(edit_link_path(product))
    expect do
      button = find(:disclosure_button, "Add cover", disabled: true)
      button.hover
      expect(button).to have_tooltip(text: "Maximum number of previews uploaded")
    end.to_not change { AssetPreview.count }
  end

  it "fails gracefully for Internet error" do
    visit(edit_link_path(product))
    expect_any_instance_of(AssetPreview).to receive(:url_or_file).and_raise(URI::InvalidURIError)
    expect do
      upload_image
      expect(page).to have_content("Could not process your preview, please try again.")
      expect(page).to_not have_selector("[role='progressbar'][aria-label='Uploading...']")
    end.to_not change { AssetPreview.count }
  end

  it "deletes previews" do
    create(:asset_preview, link: product)
    create(:asset_preview, link: product)
    visit(edit_link_path(product))
    expect(find(:section, "Cover", section_element: :section)).to have_selector("img")
    expect(product.asset_previews.alive.count).to eq(2)
    previews = all("button[role='tab'] img")
    within_section "Cover", section_element: :section do
      expect(first("img")[:src]).to eq(previews.first["src"])
      all("button[role='tab']").first.hover
      find(".remove-button[aria-label='Remove cover']").click
    end
    wait_for_ajax
    expect(product.asset_previews.alive.count).to eq(1)
    within_section "Cover", section_element: :section do
      expect(first("img")[:src]).to eq(previews.last["src"])
    end
    within_section "Cover", section_element: :section do
      find("button[role='tab']").hover
      find(".remove-button[aria-label='Remove cover']").click
      expect(page).to have_button("Upload images or videos")
      expect(page).to_not have_selector("img")
    end
    expect(product.asset_previews.alive.count).to eq(0)
  end
end
