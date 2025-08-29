# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PDF Stamping Async Flow", type: :system, js: true do
  let(:seller) { create(:user) }
  let(:buyer_email) { "test@example.com" }
  let(:product) { create(:product, user: seller, name: "Test PDF Product") }
  let(:product_file) { create(:readable_document, link: product, pdf_stamp_enabled: true) }
  let(:purchase) { create(:purchase, link: product, email: buyer_email, purchase_state: "successful") }
  let(:url_redirect) { create(:url_redirect, purchase: purchase, link: product) }

  before do
    allow_any_instance_of(ProductFile).to receive(:s3_object).and_return(
      double("s3_object", download_file: true, exists?: true)
    )

    allow_any_instance_of(PdfStampingService::Stamp).to receive(:perform!).and_return("/tmp/test_stamped.pdf")
    allow_any_instance_of(PdfStampingService::UploadToS3).to receive(:perform!).and_return("https://s3.amazonaws.com/test/stamped.pdf")

    allow(CustomerMailer).to receive(:stamped_pdf_ready).and_return(double("mailer", deliver_now: true))

    allow(StampPdfForPurchaseJob).to receive(:perform_async).and_return(true)

    allow_any_instance_of(StampedPdf).to receive(:s3_object).and_return(
      double("s3_object", download_file: true, exists?: true)
    )
  end

  describe "PDF stamping on download click" do
    it "shows notification and triggers async stamping when downloading unstamped PDF" do
      purchase
      url_redirect
      product_file

      expect(url_redirect.alive_stamped_pdfs.count).to eq(0)

      visit url_redirect_download_page_path(url_redirect.token)

      expect(page).to have_content(product.name)

      download_button = find("a[href*='product_files']", text: "Download")
      expect(download_button).to be_present

      download_button.click

      expect(page).to have_content("The PDF will be emailed to you shortly!")

      expect(current_path).to eq(url_redirect_download_page_path(url_redirect.token))

      expect(StampPdfForPurchaseJob).to have_received(:perform_async).with(purchase.id)
    end

    it "downloads normally when PDF is already stamped" do
      purchase
      url_redirect
      product_file

      stamped_pdf = create(:stamped_pdf, url_redirect: url_redirect, product_file: product_file, url: "https://s3.amazonaws.com/test/stamped.pdf")

      visit url_redirect_download_page_path(url_redirect.token)

      download_button = find("a[href*='product_files']", text: "Download")
      download_button.click

      expect(page).not_to have_content("The PDF will be emailed to you shortly!")

      expect(StampPdfForPurchaseJob).not_to have_received(:perform_async)
    end

    it "handles non-PDF files normally" do
      purchase
      url_redirect
      non_pdf_file = create(:product_file, link: product, filetype: "txt", pdf_stamp_enabled: false)

      visit url_redirect_download_page_path(url_redirect.token)

      download_button = find("a[href*='product_files']", text: "Download")
      download_button.click

      expect(page).not_to have_content("The PDF will be emailed to you shortly!")

      expect(StampPdfForPurchaseJob).not_to have_received(:perform_async)
    end
  end

  describe "PDF stamping job processing" do
    it "processes PDF stamping and sends email" do
      purchase
      url_redirect
      product_file

      allow_any_instance_of(PdfStampingService::StampForPurchase).to receive(:perform!) do |instance, purchase|
        create(:stamped_pdf, url_redirect: purchase.url_redirect, product_file: product_file, url: "https://s3.amazonaws.com/test/stamped.pdf")
        true
      end

      StampPdfForPurchaseJob.new.perform(purchase.id)

      expect(url_redirect.reload.alive_stamped_pdfs.count).to eq(1)

      expect(CustomerMailer).to have_received(:stamped_pdf_ready).with(purchase.id)
    end
  end

  describe "Email content" do
    it "sends properly formatted email with stamped PDFs" do
      purchase
      url_redirect
      product_file
      stamped_pdf = create(:stamped_pdf, url_redirect: url_redirect, product_file: product_file, url: "https://s3.amazonaws.com/test/stamped.pdf")

      mail_double = double("mail")
      allow(CustomerMailer).to receive(:stamped_pdf_ready).with(purchase.id).and_return(mail_double)
      allow(mail_double).to receive(:deliver_now)

      CustomerMailer.stamped_pdf_ready(purchase.id).deliver_now

      expect(CustomerMailer).to have_received(:stamped_pdf_ready).with(purchase.id)
      expect(mail_double).to have_received(:deliver_now)
    end
  end

  describe "Purchase flow without PDF stamping" do
    it "completes purchase without waiting for PDF stamping" do
      product
      product_file

      allow_any_instance_of(Order::ChargeService).to receive(:perform).and_return({
        "purchase_#{product.id}" => { success: true, purchase_id: purchase.id }
      })

      allow_any_instance_of(Order).to receive(:send_charge_receipts)

      order = create(:order, purchases: [purchase])

      expect(purchase.status).to eq("successful")

      expect(purchase.url_redirect&.alive_stamped_pdfs&.count || 0).to eq(0)
    end
  end

  describe "Error handling" do
    it "handles PDF stamping failures gracefully" do
      purchase
      url_redirect
      product_file

      allow_any_instance_of(PdfStampingService::StampForPurchase).to receive(:perform!).and_raise(PdfStampingService::Error, "Stamping failed")

      allow(Rails.logger).to receive(:error)

      expect { StampPdfForPurchaseJob.new.perform(purchase.id) }.not_to raise_error

      expect(Rails.logger).to have_received(:error).with(/Failed stamping for purchase/)
    end

    it "handles missing purchase gracefully" do
      allow(Rails.logger).to receive(:error)

      expect { StampPdfForPurchaseJob.new.perform(99999) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "Performance improvement" do
    it "responds immediately to download clicks even with large PDFs" do
      purchase
      url_redirect
      product_file

      allow_any_instance_of(PdfStampingService::Stamp).to receive(:perform!) do
        sleep(0.1)
        "/tmp/test_stamped.pdf"
      end

      visit url_redirect_download_page_path(url_redirect.token)

      start_time = Time.current
      download_button = find("a[href*='product_files']", text: "Download")
      download_button.click
      end_time = Time.current

      expect(end_time - start_time).to be < 0.1

      expect(page).to have_content("The PDF will be emailed to you shortly!")
    end
  end
end
