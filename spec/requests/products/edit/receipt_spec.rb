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
    it "keeps the latest unsaved message when an older preview finishes last" do
      script = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
        const originalFetch = window.fetch;
        let previewCount = 0;
        window.fetch = (...args) => {
          if (!String(args[0]).includes("receipt_preview") || previewCount++ > 0) return originalFetch(...args);
          return originalFetch(...args).then(response => new Promise(resolve => {
            window.releaseOldReceiptPreview = () => resolve(response);
          }));
        };
      JS
      page.visit "#{edit_link_path(product.unique_permalink)}/receipt"
      Selenium::WebDriver::Wait.new(timeout: 10).until do
        page.evaluate_script("typeof window.releaseOldReceiptPreview === 'function'")
      end
      fill_in "Custom message", with: "The newest receipt message"
      in_preview { expect(page).to have_text("The newest receipt message") }
      page.execute_script("window.releaseOldReceiptPreview()")
      wait_for_ajax
      in_preview { expect(page).to have_text("The newest receipt message") }
      expect(product.reload.custom_receipt_text).to be_nil
    ensure
      page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: script.fetch("identifier")) if script
    end

    it "shows live preview when the user makes changes", :js do
      visit "#{edit_link_path(product.unique_permalink)}/receipt"

      fill_in "Button text", with: "Access Content Now!"
      fill_in "Custom message", with: "Thank you for your purchase, we hope you enjoy it!"

      in_preview do
        expect(page).to have_text("Access Content Now!")
        expect(page).to have_text("Thank you for your purchase, we hope you enjoy it!")
      end
    end

    it "shows the server-rendered mail subject in the email chrome", :js do
      visit "#{edit_link_path(product.unique_permalink)}/receipt"

      in_preview do
        # The subject comes from the same Rails preview response as the rendered body
        # (ReceiptPresenter::MailSubject via the receipt preview endpoint), so it must match
        # what the real receipt email would use for this product.
        expect(page).to have_text("Subject")
        expect(page).to have_text("You bought #{product.name}!")
      end
    end
  end
end
