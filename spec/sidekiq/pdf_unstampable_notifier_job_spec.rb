# frozen_string_literal: true

require "spec_helper"

describe PdfUnstampableNotifierJob do
  describe "#perform" do
    let!(:product) { create(:product_with_pdf_file) }

    it "does not notify seller if a pdf is stampable" do
      product.product_files.alive.pdf.each { |product_file| product_file.update!(pdf_stamp_enabled: true) }

      expect(PdfStampingService).to receive(:can_stamp_file?).and_return(true)
      expect do
        described_class.new.perform(product.id)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :unstampable_pdf_notification)
    end

    it "does nothing if no files have pdf stamping enabled" do
      expect(PdfStampingService).not_to receive(:can_stamp_file?)
      expect do
        described_class.new.perform(product.id)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :unstampable_pdf_notification)
    end

    it "notifies seller if a pdf can't be stamped" do
      product.product_files.alive.pdf.each { |product_file| product_file.update!(pdf_stamp_enabled: true) }

      expect(PdfStampingService).to receive(:can_stamp_file?).and_return(false)
      expect do
        described_class.new.perform(product.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :unstampable_pdf_notification)
    end

    it "does not try to stamp a pdf that has already been marked as stampable or non-stampable" do
      product.product_files.alive.pdf.each { |product_file| product_file.update!(pdf_stamp_enabled: true, stampable_pdf: false) }
      create(:readable_document, link: product, pdf_stamp_enabled: true, stampable_pdf: true)

      expect(PdfStampingService).not_to receive(:can_stamp_file?)
      expect do
        described_class.new.perform(product.id)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :unstampable_pdf_notification)
    end

    context "with eligible sale" do
      let(:purchase) { create(:purchase, link: product) }

      before do
        product.product_files.alive.pdf.each { |product_file| product_file.update!(pdf_stamp_enabled: true) }
        purchase.create_url_redirect!
        StampPdfForPurchaseJob.jobs.clear
      end

      it "enqueues job to generate stamped pdfs for existing sales" do
        expect(PdfStampingService).to receive(:can_stamp_file?).and_return(true)
        expect do
          described_class.new.perform(product.id)
        end.not_to have_enqueued_mail(ContactingCreatorMailer, :unstampable_pdf_notification)
        expect(StampPdfForPurchaseJob.jobs.size).to eq(1)
        expect(StampPdfForPurchaseJob).to have_enqueued_sidekiq_job(purchase.id)
      end
    end
  end
end
