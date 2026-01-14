# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit Receipt Tab", type: :system, js: true) do
  include ProductEditPageHelpers
  include PreviewBoxHelpers

  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product_with_pdf_file, user: seller, size: 1024) }

  include_context "with switching account to user as admin for seller"

  describe "Receipt customization" do
    it "allows updating custom view content button text" do
      visit "#{edit_link_path(product.unique_permalink)}/receipt"

      fill_in "Button text", with: "Download Now!"

      expect do
        save_change
        product.reload
      end.to change { product.custom_view_content_button_text }.from(nil).to("Download Now!")

      expect(find_field("Button text").value).to eq("Download Now!")
    end

    it "allows updating custom receipt text" do
      visit "#{edit_link_path(product.unique_permalink)}/receipt"

      custom_text = "Thank you for your purchase! Please check your email for download instructions."

      fill_in "Custom message", with: custom_text

      expect do
        save_change
        product.reload
      end.to change { product.custom_receipt_text }.from(nil).to(custom_text)

      expect(find_field("Custom message").value).to eq(custom_text)
    end
  end

  describe "Receipt preview" do
    it "shows live preview when the user makes changes", :js do
      visit "#{edit_link_path(product.unique_permalink)}/receipt"

      fill_in "Button text", with: "Access Content Now!"
      fill_in "Custom message", with: "Thank you for your purchase, we hope you enjoy it!"

      in_preview do
        expect(page).to have_text("Access Content Now!")
        expect(page).to have_text("Thank you for your purchase, we hope you enjoy it!")
      end
    end
  end
end
