# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Product Edit Covers", type: :system, js: true do
  include ProductEditPageHelpers

  def upload_image(filenames)
    click_on "Upload images or videos"
    page.attach_file(filenames.map { |filename| file_fixture(filename) }) do
      select_tab "Computer files"
    end
  end

  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product_with_pdf_file, user: seller, size: 1024) }

  before do
    product.shipping_destinations << ShippingDestination.new(
      country_code: Product::Shipping::ELSEWHERE,
      one_item_rate_cents: 0,
      multiple_items_rate_cents: 0
    )
  end

  include_context "with switching account to user as admin for seller"

  it "supports attaching covers" do
    visit edit_link_path(product.unique_permalink)
    upload_image(["test.png"])
    wait_for_ajax
    sleep 1

    select_disclosure "Add cover" do
      upload_image(["test-small.jpg"])
    end
    wait_for_ajax

    within_section "Cover", section_element: :section do
      expect(page).to have_selector("button[role='tab']", count: 2)
    end
  end

  it "instantly previews product cover changes" do
    visit edit_link_path(product.unique_permalink)

    upload_image(["test.png"])

    wait_for_ajax

    in_preview do
      expect(page).to have_selector("[aria-label='Product preview'] img")
    end
  end

  it "does not allow uploading invalid images" do
    visit edit_link_path(product.unique_permalink)
    upload_image(["disguised_html_script.png"])
    allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
    expect(page).to have_alert(text: "Could not process your preview, please try again.")
  end

  it "allows uploading valid image after trying an invalid one" do
    visit edit_link_path(product.unique_permalink)
    upload_image(["disguised_html_script.png"])
    allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
    expect(page).to have_alert(text: "Could not process your preview, please try again.")
    upload_image(["test-small.jpg"])
    wait_for_ajax
    within_section "Cover", section_element: :section do
      expect(page).to have_selector("button[role='tab']", count: 1)
    end
  end

  it "allows uploading video files" do
    visit edit_link_path(product.unique_permalink)
    upload_image(["ScreenRecording.mov"])
    wait_for_ajax
    within_section "Cover", section_element: :section do
      expect(page).to have_selector("button[role='tab']", count: 1)
    end
  end

  it("allows multiple images to be uploaded simultaneously") do
    visit edit_link_path(product.unique_permalink)
    upload_image(["test-small.jpg", "test.png"])
    wait_for_ajax
    within_section "Cover", section_element: :section do
      expect(page).to have_selector("button[role='tab']", count: 2)
    end
  end

  it("does not allow more than 8 images to be uploaded simultaneously") do
    allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
    visit edit_link_path(product.unique_permalink)
    upload_image([
                   "test-small.jpg",
                   "test.png",
                   "test.jpg",
                   "test.gif",
                   "smilie.png",
                   "test-small.jpg",
                   "test-small.png",
                   "test-squashed.png",
                   "Austin's Mojo.png"
                 ])
    wait_for_ajax
    expect(page).to have_alert(text: "Sorry, we have a limit of 8 previews. Please delete an existing one before adding another.")
    within_section "Cover", section_element: :section do
      expect(page).to have_selector("button[role='tab']", count: 8)
    end
  end

  describe "External links" do
    it "allows attaching embeds from a supported provider" do
      vcr_turned_on do
        VCR.use_cassette("Product Edit Covers - External links - Supported provider") do
          visit edit_link_path(product.unique_permalink)

          expect do
            within_section "Cover", section_element: "section" do
              click_on "Upload images or videos"
              select_tab "External link"
              fill_in "https://", with: "https://youtu.be/YE7VzlLtp-4"
              click_on "Upload"
            end

            expect(page).to_not have_alert(text: "A URL from an unsupported platform was provided. Please try again.")
            within_section "Cover", section_element: :section do
              expect(page).to have_selector("button[role='tab'] img[src='https://i.ytimg.com/vi/YE7VzlLtp-4/hqdefault.jpg']")
            end
          end.to change { AssetPreview.count }.by(1)
        end
      end
    end

    it "does not allow attaching embeds from unsupported providers" do
      vcr_turned_on do
        VCR.use_cassette("Product Edit Covers - External links - Unsupported provider") do
          visit edit_link_path(product.unique_permalink)

          expect do
            within_section "Cover", section_element: "section" do
              click_on "Upload images or videos"
              select_tab "External link"
              fill_in "https://", with: "https://www.tiktok.com/@soflofooodie/video/7164885074863787307"
              click_on "Upload"
            end

            expect(page).to have_alert(text: "A URL from an unsupported platform was provided. Please try again.")
          end.to_not change { AssetPreview.count }
        end
      end
    end
  end

  it "allows to re-order covers" do
    asset1 = create(:asset_preview, link: product)
    asset2 = create(:asset_preview, link: product)
    asset3 = create(:asset_preview, link: product)

    visit edit_link_path(product.unique_permalink)

    within_section "Cover", section_element: :section do
      preview_mini_node1 = all("button[role='tab']")[0]
      preview_mini_node2 = all("button[role='tab']")[1]
      preview_mini_node3 = all("button[role='tab']")[2]

      expect(preview_mini_node1).not_to be nil
      expect(preview_mini_node2).not_to be nil
      expect(preview_mini_node3).not_to be nil

      # Fix flaky spec when the banner component is present.
      page.scroll_to preview_mini_node3, align: :center

      preview_mini_node2.drag_to preview_mini_node3
    end

    save_change

    expect(product.reload.display_asset_previews.pluck(:id)).to eq [
      asset1.id,
      asset3.id,
      asset2.id
    ]
  end
end
