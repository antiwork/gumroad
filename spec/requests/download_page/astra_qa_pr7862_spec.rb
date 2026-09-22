# frozen_string_literal: true

require("spec_helper")

# Local-branch QA for gumroad#7862 (receipt before stamping / download gating).
# Not part of the PR: evidence only. Captures the rendered download page for a
# stampable purchase whose stamped copy does not exist yet.
describe("Download Page", type: :system, js: true) do
  describe "receipt-before-stamp QA (local branch boot)" do
    it "renders the download page and warns the buyer while the stamped copy is missing" do
      product = create(:product, name: "QA Stampable Product")
      file = create(:readable_document, link: product, pdf_stamp_enabled: true)
      purchase = create(:purchase, link: product)
      url_redirect = create(:url_redirect, purchase:)
      url_redirect.update!(is_done_pdf_stamping: true)

      visit url_redirect.download_page_url
      expect(page).to have_text("QA Stampable Product")
      page.save_screenshot("/tmp/pr7862-qa-1-download-page.png")

      click_on "Download"
      expect(page).to have_current_path(url_redirect.download_page_url)
      expect(page).to have_text("We are preparing the file for download. You will receive an email when it is ready.")
      page.save_screenshot("/tmp/pr7862-qa-2-preparing-warning.png")

      expect(StampPdfForPurchaseJob).to have_enqueued_sidekiq_job(purchase.id, true).on("critical")
      expect(PdfStampingService.buyer_notification_requested?(purchase.id)).to be(true)

      create(:stamped_pdf, url_redirect:, product_file: file)
      expect(url_redirect.reload.missing_stamped_pdf?(file)).to be(false)
      # Post-stamp download is covered by url_redirects_controller_spec ("signs the stamped
      # copy instead of the original upload"); signing a real object here would need a MinIO
      # fixture object this environment does not have.
    end
  end
end