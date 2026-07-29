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

    context "with a PDF that has heading bookmarks (a document outline)" do
      # Regression coverage for a creator report: stamping was rebuilding the PDF by splitting it and
      # concatenating the pieces back together, which silently discarded the document outline (the
      # heading bookmarks readers use to navigate) and the Title/Author metadata. Long technical books
      # lost their whole navigation tree, so the only workaround was turning stamping off.
      let(:fixture_path) { Rails.root.join("spec", "support", "fixtures", "pdf-with-bookmarks.pdf") }

      before do
        # Yield the local fixture instead of hitting S3, so the assertions below are about stamping.
        allow(product_file).to receive(:download_original) do |&block|
          File.open(fixture_path, "rb") { |file| block.call(file) }
        end
        allow(product_file).to receive(:s3_url).and_return("#{S3_BASE_URL}specs/pdf-with-bookmarks.pdf")
      end

      def outline_entry_count(path)
        reader = PDF::Reader.new(path)
        catalog = reader.objects.deref(reader.objects.trailer[:Root])
        return 0 if catalog[:Outlines].nil?

        outlines = reader.objects.deref(catalog[:Outlines])
        outlines[:Count].to_i
      end

      # A bookmark is only useful if it still points at a page, so check the first entry's title and
      # that its destination resolves to a real page object, not just that the outline tree exists.
      def first_outline_entry(path)
        reader = PDF::Reader.new(path)
        catalog = reader.objects.deref(reader.objects.trailer[:Root])
        outlines = reader.objects.deref(catalog[:Outlines])
        first = reader.objects.deref(outlines[:First])
        destination = reader.objects.deref(first[:Dest])
        target = destination.is_a?(Array) ? reader.objects.deref(destination.first) : nil
        [decode_pdf_text(first[:Title]), target && target[:Type]]
      end

      # PDF text strings are either PDFDocEncoded or UTF-16BE with a byte-order mark; Prawn writes
      # the latter, so decode it rather than comparing raw bytes.
      def decode_pdf_text(value)
        bytes = value.to_s.dup.force_encoding(Encoding::BINARY)
        return bytes.byteslice(2..).force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8) if bytes.start_with?("\xFE\xFF".b)

        bytes.force_encoding(Encoding::UTF_8)
      end

      it "preserves the bookmarks and the document metadata" do
        expect(outline_entry_count(fixture_path.to_s)).to eq(5)

        stamped_path = described_class.perform!(product_file:, watermark_text:)

        expect(outline_entry_count(stamped_path)).to eq(5)

        title, destination_type = first_outline_entry(stamped_path)
        expect(title).to eq("Chapter 1")
        expect(destination_type).to eq(:Page)

        info = PDF::Reader.new(stamped_path).info
        expect(info[:Title]).to eq("Book With Bookmarks")
        expect(info[:Author]).to eq("Test Author")
      end

      it "still stamps the first page only" do
        stamped_path = described_class.perform!(product_file:, watermark_text:)
        reader = PDF::Reader.new(stamped_path)

        expect(reader.page_count).to eq(5)
        expect(reader.page(1).text).to include("Sold to")
        expect(reader.page(1).text).to include(watermark_text)
        (2..reader.page_count).each do |page_number|
          expect(reader.page(page_number).text).not_to include("Sold to")
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

      context "when the stamping command fails" do
        before do
          # `exitstatus` drives the success check now, because qpdf uses exit 3 for "recovered from
          # problems but wrote valid output". 2 is a genuine failure.
          allow(Open3).to receive(:capture3).and_return(
            ["stdout message", "stderr line1\nstderr line2", OpenStruct.new(success?: false, exitstatus: 2)]
          )
          allow(Rails.logger).to receive(:error)
        end

        it "logs and raises PdfStampingService::Stamp::Error" do
          expect(Rails.logger).to receive(:error).with(
            /\[PdfStampingService::Stamp.apply_watermark!\] Failed to execute command: qpdf/
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
