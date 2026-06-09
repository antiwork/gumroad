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

    context "with an encrypted PDF that opens without a password" do
      let(:pdf) { create(:readable_document, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/encrypted_pdf.pdf") }

      it "decrypts it and returns true" do
        expect(Rails.logger).not_to receive(:error)
        result = described_class.can_stamp_file?(product_file: pdf)
        expect(result).to eq(true)
      end
    end

    context "with a password-protected PDF that requires a password to open" do
      let(:pdf) { create(:readable_document, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/password_protected_pdf.pdf") }

      it "returns false" do
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
        result = method.call(**args)
        created_file_paths << result
        result
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

    it "stamps only the first page of the PDF" do
      original_page_count = nil
      product_file.download_original do |original_pdf|
        original_page_count = PDF::Reader.new(original_pdf.path).page_count
      end

      stamped_path = described_class.perform!(product_file:, watermark_text:)

      reader = PDF::Reader.new(stamped_path)
      expect(reader.page_count).to eq(original_page_count)

      first_page_text = reader.page(1).text
      expect(first_page_text).to include("Sold to")
      expect(first_page_text).to include(watermark_text)

      if reader.page_count > 1
        (2..reader.page_count).each do |page_num|
          page_text = reader.page(page_num).text
          expect(page_text).not_to include("Sold to")
        end
      end
    end

    context "with an encrypted PDF that opens without a password" do
      let(:pdf_url) { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/encrypted_pdf.pdf" }

      it "decrypts and stamps it without errors" do
        expect(Rails.logger).not_to receive(:error)

        stamped_path = nil
        expect do
          stamped_path = described_class.perform!(product_file:, watermark_text:)
        end.not_to raise_error

        first_page_text = PDF::Reader.new(stamped_path).page(1).text
        expect(first_page_text).to include(watermark_text)
      end
    end

    context "when applying the watermark fails" do
      context "when the PDF requires a password to open" do
        let(:pdf_url) { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/password_protected_pdf.pdf" }

        it "raises a rescuable PDF::Reader::EncryptedPDFError" do
          expect do
            described_class.perform!(product_file:, watermark_text:)
          end.to raise_error(PDF::Reader::EncryptedPDFError)

          expect(PdfStampingService::ERRORS_TO_RESCUE).to include(PDF::Reader::EncryptedPDFError)
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
