# frozen_string_literal: true

require "spec_helper"

describe PdfStampingService::StampForPurchase do
  describe ".perform!" do
    let(:product) { create(:product) }
    let(:purchase) { create(:purchase, link: product) }

    before do
      purchase.create_url_redirect!
    end

    context "with stampable PDFs" do
      let!(:product_file_one) { create(:readable_document, pdf_stamp_enabled: true) }

      before do
        product.product_files << product_file_one
      end

      it "creates stamp_pdf and updates url_redirect" do
        url_redirect = purchase.url_redirect
        expect do
          expect(described_class.perform!(purchase)).to be(true)
        end.to change { url_redirect.reload.stamped_pdfs.count }.by(1)

        stamped_pdf = url_redirect.stamped_pdfs.first
        expect(stamped_pdf.product_file).to eq(product_file_one)
        expect(stamped_pdf.url).to match(/#{AWS_S3_ENDPOINT}/o)
        expect(url_redirect.reload.is_done_pdf_stamping?).to eq(true)
      end

      context "with encrypted stampable PDFs" do
        let!(:product_file_two) { create(:readable_document, pdf_stamp_enabled: true, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/encrypted_pdf.pdf") }
        let!(:product_file_three) { create(:readable_document, pdf_stamp_enabled: true) }
        let!(:product_file_four) { create(:readable_document, pdf_stamp_enabled: false, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/encrypted_pdf.pdf") }

        before do
          product.product_files << product_file_one
          product.product_files << product_file_two
          product.product_files << product_file_three
          product.product_files << product_file_four
        end

        it "stamps all files and raises" do
          url_redirect = purchase.url_redirect

          error_message = \
            "Failed to stamp 1 file(s) for purchase #{purchase.id} - " \
            "File #{product_file_two.id}: PdfStampingService::Stamp::Error: Error generating stamped PDF: PDF is encrypted."
          expect do
            expect do
              expect(described_class.perform!(purchase)).to be(true)
            end.to change { url_redirect.reload.stamped_pdfs.count }.by(2)
          end.to raise_error(PdfStampingService::Error).with_message(error_message)

          expect_stamped_pdf(url_redirect.stamped_pdfs.first, product_file_one)
          expect_stamped_pdf(url_redirect.stamped_pdfs.second, product_file_three)
          expect(url_redirect.reload.is_done_pdf_stamping?).to eq(false)
        end

        def expect_stamped_pdf(stamped_pdf, product_file)
          expect(stamped_pdf.product_file).to eq(product_file)
          expect(stamped_pdf.url).to match(/#{AWS_S3_ENDPOINT}/o)
        end
      end
    end

    context "when the product doesn't have stampable PDFs" do
      it "does nothing" do
        expect(described_class.perform!(purchase)).to eq(nil)
      end
    end
  end
end
