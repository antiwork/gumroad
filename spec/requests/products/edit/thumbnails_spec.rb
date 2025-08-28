# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit Thumbnail Scenario", type: :system, js: true) do
  include ManageSubscriptionHelpers

  let(:seller) { create(:named_seller) }

  before :each do
    @product = create(:product_with_pdf_file, user: seller, size: 1024)
    @product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE,
                                                              one_item_rate_cents: 0,
                                                              multiple_items_rate_cents: 0)
  end

  include_context "with switching account to user as admin for seller"

  it "allows uploading images as thumbnails and validates them" do
    visit("/products/#{@product.unique_permalink}/edit")

    within_section "Thumbnail", section_element: :section do
      page.attach_file("Upload", file_fixture("sample.mov"), visible: false)
    end
    expect(page).to have_alert(text: "Invalid file type.")
    expect(page).to have_no_alert

    within_section "Thumbnail", section_element: :section do
      page.attach_file("Upload", file_fixture("error_file.jpeg"), visible: false)
    end
    expect(page).to have_alert(text: "Could not process your thumbnail, please upload an image with size smaller than 5 MB")
    expect(page).to have_no_alert

    within_section "Thumbnail", section_element: :section do
      page.attach_file("Upload", file_fixture("test-small.png"), visible: false)
    end
    expect(page).to have_alert(text: "Image must be at least 600x600px.")
    expect(page).to have_no_alert

    within_section "Thumbnail", section_element: :section do
      page.attach_file("Upload", file_fixture("test-squashed-horizontal.gif"), visible: false)
    end
    expect(page).to have_alert(text: "Image must be square.")
    expect(page).to have_no_alert

    within_section "Thumbnail", section_element: :section do
      page.attach_file("Upload", file_fixture("disguised_html_script.png"), visible: false)
    end
    expect(page).to have_alert(text: "Invalid file type.")
    expect(page).to have_no_alert

    within_section "Thumbnail", section_element: :section do
      page.attach_file("Upload", file_fixture("smilie.png"), visible: false)
      expect(page).to have_selector("[role=progressbar]")
      wait_for_ajax
      expect(page).to_not have_selector("[role=progressbar]")
      expect(page).to have_image("Thumbnail image", src: @product.reload.thumbnail.url)
    end
    expect(page).to have_no_alert

    expect(@product.reload.thumbnail).to be_present
  end

  context "when product has a saved thumbnail" do
    before do
      create(:thumbnail, product: @product)
      @product.reload

      visit("/products/#{@product.unique_permalink}/edit")
    end

    it "shows the thumbnail" do
      expect(page).to have_image("Thumbnail image", src: @product.thumbnail.url)
    end

    it "allows user to remove the thumbnail and persists the removal immediately" do
      within_section "Thumbnail", section_element: :section do
        click_on "Remove"
      end
      wait_for_ajax

      expect(page).to have_alert(text: "Thumbnail has been deleted.")

      within_section "Thumbnail", section_element: :section do
        expect(page).to_not have_image
        expect(page).to have_field("Upload", visible: false)
      end

      expect(@product.reload.thumbnail).not_to be_alive
    end
  end
end
