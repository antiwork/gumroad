# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PDF Stamping Integration Test", type: :integration do
  describe "End-to-end PDF stamping flow" do
    it "completes the full PDF stamping workflow" do
      seller = create(:user, email: "seller@example.com")
      product = create(:product, user: seller, name: "Test PDF Product", price_cents: 1000)
      product_file = create(:readable_document, link: product, pdf_stamp_enabled: true)

      purchase = create(:purchase,
        link: product,
        email: "buyer@example.com",
        purchase_state: "successful",
        price_cents: 1000
      )

      url_redirect = create(:url_redirect, purchase: purchase, link: product)

      expect(url_redirect.alive_stamped_pdfs.count).to eq(0)
      expect(product_file.must_be_pdf_stamped?).to be true

      allow_any_instance_of(PdfStampingService::Stamp).to receive(:perform!).and_return("/tmp/test_stamped.pdf")
      allow_any_instance_of(PdfStampingService::UploadToS3).to receive(:perform!).and_return("https://s3.amazonaws.com/test/stamped.pdf")

      mail_double = double("mail")
      allow(CustomerMailer).to receive(:stamped_pdf_ready).with(purchase.id).and_return(mail_double)
      allow(mail_double).to receive(:deliver_now)

      if product_file.must_be_pdf_stamped? && !url_redirect.alive_stamped_pdfs.exists?(product_file_id: product_file.id)
        StampPdfForPurchaseJob.new.perform(purchase.id)

        expect(url_redirect.reload.alive_stamped_pdfs.count).to eq(1)

        expect(CustomerMailer).to have_received(:stamped_pdf_ready).with(purchase.id)
        expect(mail_double).to have_received(:deliver_now)

        stamped_pdf = url_redirect.alive_stamped_pdfs.first
        expect(stamped_pdf.product_file).to eq(product_file)
        expect(stamped_pdf.url).to eq("https://s3.amazonaws.com/test/stamped.pdf")
      end
    end

    it "handles multiple PDFs correctly" do
      seller = create(:user)
      product = create(:product, user: seller)

      pdf1 = create(:readable_document, link: product, pdf_stamp_enabled: true)
      pdf2 = create(:readable_document, link: product, pdf_stamp_enabled: true)
      txt_file = create(:product_file, link: product, filetype: "txt", pdf_stamp_enabled: false)

      purchase = create(:purchase, link: product, purchase_state: "successful")
      url_redirect = create(:url_redirect, purchase: purchase, link: product)

      allow_any_instance_of(PdfStampingService::Stamp).to receive(:perform!).and_return("/tmp/test_stamped.pdf")
      allow_any_instance_of(PdfStampingService::UploadToS3).to receive(:perform!).and_return("https://s3.amazonaws.com/test/stamped.pdf")

      mail_double = double("mail")
      allow(CustomerMailer).to receive(:stamped_pdf_ready).with(purchase.id).and_return(mail_double)
      allow(mail_double).to receive(:deliver_now)

      StampPdfForPurchaseJob.new.perform(purchase.id)

      expect(url_redirect.reload.alive_stamped_pdfs.count).to eq(2)

      expect(CustomerMailer).to have_received(:stamped_pdf_ready).with(purchase.id)
    end

    it "skips already stamped PDFs" do
      seller = create(:user)
      product = create(:product, user: seller)
      product_file = create(:readable_document, link: product, pdf_stamp_enabled: true)

      purchase = create(:purchase, link: product, purchase_state: "successful")
      url_redirect = create(:url_redirect, purchase: purchase, link: product)

      stamped_pdf = create(:stamped_pdf, url_redirect: url_redirect, product_file: product_file)

      allow_any_instance_of(PdfStampingService::Stamp).to receive(:perform!).and_return("/tmp/test_stamped.pdf")
      allow_any_instance_of(PdfStampingService::UploadToS3).to receive(:perform!).and_return("https://s3.amazonaws.com/test/stamped.pdf")

      StampPdfForPurchaseJob.new.perform(purchase.id)

      expect(url_redirect.reload.alive_stamped_pdfs.count).to eq(1)
      expect(url_redirect.alive_stamped_pdfs.first).to eq(stamped_pdf)
    end
  end

  describe "Controller integration" do
    it "handles download requests correctly" do
      seller = create(:user)
      product = create(:product, user: seller)
      product_file = create(:readable_document, link: product, pdf_stamp_enabled: true)
      purchase = create(:purchase, link: product, purchase_state: "successful")
      url_redirect = create(:url_redirect, purchase: purchase, link: product)

      allow(StampPdfForPurchaseJob).to receive(:perform_async).and_return(true)

      get url_redirect_download_product_files_path(url_redirect.token, product_file_ids: [product_file.external_id])

      expect(response).to have_http_status(:redirect)
      expect(response).to redirect_to(url_redirect_download_page_path(url_redirect.token))

      expect(StampPdfForPurchaseJob).to have_received(:perform_async).with(purchase.id)
    end
  end
end
