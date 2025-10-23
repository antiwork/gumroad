# frozen_string_literal: true

require "spec_helper"

describe PdfStampingService::Stamp do
  describe ".can_stamp_file?" do
    context "with readable PDF" do
      let(:pdf) { create(:readable_document, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/billion-dollar-company-chapter-0.pdf") }

      it "returns true" do
        result = described_class.can_stamp_file?(product_file: pdf)
        expect(result).to eq(true)
      end
    end

    context "with encrypted PDF" do
      let(:pdf) { create(:readable_document, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/encrypted_pdf.pdf") }

      it "logs and returns false" do
        expect(Rails.logger).to receive(:error).with(
          /\[PdfStampingService::Stamp.apply_watermark!\] Failed to execute command: pdftk/
        )
        expect(Rails.logger).to receive(:error).with(/\[PdfStampingService::Stamp.apply_watermark!\] STDOUT: /)
        expect(Rails.logger).to receive(:error).with(/\[PdfStampingService::Stamp.apply_watermark!\] STDERR: /)
        result = described_class.can_stamp_file?(product_file: pdf)
        expect(result).to eq(false)
      end
    end
  end

  describe ".perform!" do
    let(:pdf_url) { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/billion-dollar-company-chapter-0.pdf" }
    let(:product_file) { create(:readable_document, url: pdf_url) }
    let(:watermark_text) { "customer@example.com" }
    let(:created_file_paths) { [] }

    before do
      allow(described_class).to receive(:perform!).and_wrap_original do |method, **args|
        created_file_paths << method.call(**args)
      end
    end

    after(:each) do
      created_file_paths.each { FileUtils.rm_f(_1) }
      created_file_paths.clear
    end

    it "stamps the PDF without errors" do
      expect(Rails.logger).not_to receive(:error)
      expect do
        described_class.perform!(product_file:, watermark_text:)
      end.not_to raise_error
    end

    context "when applying the watermark fails" do
      context "when the PDF is encrypted" do
        let(:pdf_url) { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/encrypted_pdf.pdf" }

        it "logs and raises PdfStampingService::Stamp::Error" do
          expect(Rails.logger).to receive(:error).with(
            /\[PdfStampingService::Stamp.apply_watermark!\] Failed to execute command: pdftk/
          )
          expect(Rails.logger).to receive(:error).with(/\[PdfStampingService::Stamp.apply_watermark!\] STDOUT: /)
          expect(Rails.logger).to receive(:error).with(/\[PdfStampingService::Stamp.apply_watermark!\] STDERR: /)

          expect do
            described_class.perform!(product_file:, watermark_text:)
          end.to raise_error(PdfStampingService::Stamp::Error).with_message("Error generating stamped PDF: PDF is encrypted.")
        end
      end

      context "when pdftk command fails" do
        before do
          allow(Open3).to receive(:capture3).and_return(
            ["stdout message", "stderr line1\nstderr line2", OpenStruct.new(success?: false)]
          )
          allow(Rails.logger).to receive(:error)
        end

        it "logs and raises PdfStampingService::Stamp::Error" do
          expect(Rails.logger).to receive(:error).with(
            /\[PdfStampingService::Stamp.apply_watermark!\] Failed to execute command: pdftk/
          )
          expect(Rails.logger).to receive(:error).with(
            "[PdfStampingService::Stamp.apply_watermark!] STDOUT: stdout message"
          )
          expect(Rails.logger).to receive(:error).with(
            "[PdfStampingService::Stamp.apply_watermark!] STDERR: stderr line1\nstderr line2"
          )

          expect do
            described_class.perform!(product_file:, watermark_text: "customer@example.com")
          end.to raise_error(PdfStampingService::Stamp::Error).with_message("Error generating stamped PDF: stderr line1")
        end
      end
    end
  end
end
