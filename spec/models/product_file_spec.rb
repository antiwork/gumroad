# frozen_string_literal: true

require "spec_helper"

describe ProductFile do
  describe "parent presence" do
    # A file's parent is what gives it a delivery path and an owner: a product
    # file is downloaded from the product, an installment file is delivered with
    # the post. With no parent it can be reached from neither, and with both it
    # is ambiguous which surface governs access. The check used to be declared
    # with `on: :save`, which is not a Rails context, so it never ran.
    it "rejects a file that belongs to neither a product nor an installment" do
      file = build(:product_file, link: nil, installment: nil)

      expect(file).to be_invalid
      expect(file.errors.full_messages).to include("A file needs to either belong to a product or an installment")
    end

    it "rejects a file that belongs to both a product and an installment" do
      file = build(:product_file, link: create(:product), installment: create(:installment))

      expect(file).to be_invalid
      expect(file.errors.full_messages).to include("A file needs to either belong to a product or an installment")
    end

    it "accepts a file that belongs to a product" do
      expect(build(:product_file, link: create(:product))).to be_valid
    end

    it "accepts a file that belongs to an installment" do
      expect(build(:product_file, link: nil, installment: create(:installment))).to be_valid
    end

    it "keeps rejecting a parentless file on update, not just on create" do
      file = create(:product_file, link: create(:product))

      expect(file.update(link: nil)).to be(false)
      expect(file.errors.full_messages).to include("A file needs to either belong to a product or an installment")
      expect(file.reload.link).to be_present
    end

    it "rejects a saved file that a direct column write left without a parent" do
      file = create(:product_file, link: create(:product))
      file.update_columns(link_id: nil, installment_id: nil)

      expect(file.reload).to be_invalid
      expect(file.errors.full_messages).to include("A file needs to either belong to a product or an installment")
    end

    it "keeps rejecting a file left with no parent when its installment is stripped" do
      file = create(:product_file, link: nil, installment: create(:installment))

      expect(file.update(installment: nil)).to be(false)
      expect(file.errors.full_messages).to include("A file needs to either belong to a product or an installment")
      expect(file.reload.installment).to be_present
    end

    it "accepts a write that gives a parentless file a single parent" do
      file = create(:product_file, link: create(:product))
      file.update_columns(link_id: nil, installment_id: nil)

      expect(file.reload.update(link: create(:product))).to eq(true)
    end
  end

  describe ".archivable" do
    it "only includes archivable files" do
      create(:streamable_video)
      create(:readable_document)
      create(:listenable_audio)
      create(:non_readable_document)
      create(:external_link)
      create(:streamable_video, stream_only: true)
      create(:product_file, filetype: "link", url: "https://www.gumroad.com")
      create(:product_file, filetype: "link", url: "https://www.twitter.com")
      expect(ProductFile.archivable.count).to eq(4)
    end
  end

  describe "#has_alive_duplicate_files?" do
    let!(:file_1) { create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/some-file.pdf") }
    let!(:file_2) { create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/some-file.pdf") }

    it "returns true if there's an alive record with the same url" do
      file_1.mark_deleted
      expect(file_1.has_alive_duplicate_files?).to eq(true)
      expect(file_2.has_alive_duplicate_files?).to eq(true)
    end

    it "returns false if there's no other alive record with the same url" do
      file_1.mark_deleted
      file_2.mark_deleted
      expect(file_1.has_alive_duplicate_files?).to eq(false)
      expect(file_2.has_alive_duplicate_files?).to eq(false)
    end
  end

  describe "#can_send_to_kindle?" do
    context "when file size is above the limit" do
      it "returns false" do
        product_file = create(:readable_document, size: 20_480_001)

        expect(product_file.can_send_to_kindle?).to eq false
      end
    end

    context "when the file size is nil" do
      it "returns false" do
        product_file = create(:readable_document, size: nil)

        expect(product_file.can_send_to_kindle?).to eq false
      end
    end

    context "when the file format is not supported by kindle" do
      it "returns false" do
        product_file = create(:streamable_video, size: 10_000)

        expect(product_file.can_send_to_kindle?).to eq false
      end
    end

    context "when the file format is supported by kindle" do
      it "returns true for pdf files" do
        product_file = create(:pdf_product_file, size: 10_000)

        expect(product_file.can_send_to_kindle?).to eq true
      end

      it "returns true for epub files" do
        product_file = create(:epub_product_file, size: 10_000)

        expect(product_file.can_send_to_kindle?).to eq true
      end
    end
  end

  describe "#readable?" do
    it "returns true for PDF files" do
      expect(build(:readable_document).readable?).to eq(true)
    end

    it "returns true for EPUB files" do
      expect(build(:epub_product_file).readable?).to eq(true)
    end

    it "returns false for other file types" do
      expect(build(:non_readable_document).readable?).to eq(false)
      expect(build(:streamable_video).readable?).to eq(false)
      expect(build(:listenable_audio).readable?).to eq(false)
      expect(build(:external_link).readable?).to eq(false)
    end
  end

  describe "#browser_readable?" do
    it "allows PDFs and EPUBs with a missing or bounded size" do
      expect(build(:readable_document, size: nil).browser_readable?).to eq(true)
      expect(build(:epub_product_file, size: nil).browser_readable?).to eq(true)
      expect(build(:epub_product_file, size: ProductFile::MAX_EPUB_READER_ARCHIVE_SIZE).browser_readable?).to eq(true)
    end

    it "keeps known oversized EPUBs download-only" do
      product_file = build(:epub_product_file, size: ProductFile::MAX_EPUB_READER_ARCHIVE_SIZE + 1)

      expect(product_file.browser_readable?).to eq(false)
      expect(product_file.readable?).to eq(true)
    end
  end

  describe "#content_length" do
    it "uses 100 for EPUB percentage progress" do
      expect(build(:epub_product_file, pagelength: 12).content_length).to eq(100)
    end
  end

  describe "#media_location_for_download_page" do
    it "keeps a native EPUB location in the final section below completion" do
      product_file = build(:epub_product_file, pagelength: 13)
      media_location = MediaLocation.new(
        product_file:,
        location: 13,
        unit: MediaLocation::Unit::PAGE_NUMBER,
        consumed_at: Time.current
      )

      expect(product_file.media_location_for_download_page(media_location)).to include(
        location: 99,
        unit: MediaLocation::Unit::PERCENTAGE
      )
      expect(product_file.media_location_for_download_page(media_location)).not_to have_key(:cfi)
    end

    it "does not mark the penultimate native EPUB page complete" do
      product_file = build(:epub_product_file, pagelength: 200)
      media_location = MediaLocation.new(
        product_file:,
        location: 199,
        unit: MediaLocation::Unit::PAGE_NUMBER,
        consumed_at: Time.current
      )

      expect(product_file.media_location_for_download_page(media_location)).to include(
        location: 99,
        unit: MediaLocation::Unit::PERCENTAGE
      )
    end

    it "suppresses legacy EPUB progress when there is no section count" do
      product_file = build(:epub_product_file, pagelength: nil)
      media_location = MediaLocation.new(
        product_file:,
        location: 5,
        unit: MediaLocation::Unit::PAGE_NUMBER,
        consumed_at: Time.current
      )

      expect(product_file.media_location_for_download_page(media_location)).to be_nil
    end

    it "normalizes progress from the fields selected by the download-page poll" do
      product_file = create(:epub_product_file, pagelength: 13)
      selected_file = ProductFile.select(:id, :filetype, :filegroup, :pagelength).find(product_file.id)
      media_location = MediaLocation.new(
        product_file: selected_file,
        location: 4,
        unit: MediaLocation::Unit::PAGE_NUMBER,
        consumed_at: Time.current
      )

      expect(selected_file.media_location_for_download_page(media_location)).to include(
        location: 30,
        unit: MediaLocation::Unit::PERCENTAGE
      )
    end
  end

  describe "#epub_location_for_mobile" do
    it "provides the exact spine section and completion separately" do
      product_file = build(:epub_product_file, pagelength: 13)
      media_location = MediaLocation.new(
        product_file:,
        location: 75,
        unit: MediaLocation::Unit::PERCENTAGE,
        epub_cfi: "epubcfi(/6/8!/4/2/1:0)",
        consumed_at: Time.current
      )

      expect(product_file.epub_location_for_mobile(media_location)).to include(
        cfi: media_location.epub_cfi,
        percentage: 75,
        page_number: 4,
        completed: false
      )
      media_location.location = 100
      expect(product_file.epub_location_for_mobile(media_location)).to include(completed: true)
    end

    it "keeps a partial one-section locator valid and incomplete" do
      product_file = build(:epub_product_file, pagelength: 1)
      media_location = MediaLocation.new(
        product_file:,
        location: 50,
        unit: MediaLocation::Unit::PERCENTAGE,
        epub_cfi: "epubcfi(/6/2!/4/2/1:0)",
        consumed_at: Time.current
      )

      expect(product_file.epub_location_for_mobile(media_location)).to include(page_number: 1, completed: false)
    end
  end

  describe "#media_location_for_mobile" do
    it "derives the legacy page from the CFI and reserves completion for 100 percent" do
      product_file = build(:epub_product_file, pagelength: 13)
      media_location = MediaLocation.new(
        product_file:,
        location: 75,
        unit: MediaLocation::Unit::PERCENTAGE,
        epub_cfi: "epubcfi(/6/8!/4/2/1:0)",
        consumed_at: Time.current
      )

      expect(product_file.media_location_for_mobile(media_location)).to include(location: 4)
      media_location.epub_cfi = "epubcfi(/6/26!/4/2/1:0)"
      media_location.location = 99
      expect(product_file.media_location_for_mobile(media_location)).to include(location: 12)
      media_location.epub_cfi = "epubcfi(/6/24!/4/2/1:0)"
      media_location.location = 100
      expect(product_file.media_location_for_mobile(media_location)).to include(location: 13)
    end

    it "omits an incomplete one-section legacy sentinel" do
      product_file = build(:epub_product_file, pagelength: 1)
      media_location = MediaLocation.new(
        product_file:,
        location: 50,
        unit: MediaLocation::Unit::PERCENTAGE,
        epub_cfi: "epubcfi(/6/2!/4/2/1:0)",
        consumed_at: Time.current
      )

      expect(product_file.media_location_for_mobile(media_location)).to be_nil
    end
  end

  describe "#media_location_compatible?" do
    it "rejects an EPUB percentage after the file is replaced with a PDF" do
      product_file = build(:readable_document)
      media_location = MediaLocation.new(
        product_file:,
        location: 42,
        unit: MediaLocation::Unit::PERCENTAGE,
        epub_cfi: "epubcfi(/6/4!/4/2/8:0)",
        consumed_at: Time.current
      )

      expect(product_file.media_location_compatible?(media_location)).to be(false)
      expect(product_file.media_location_for_download_page(media_location)).to be_nil
    end

    it "rejects stale percentage progress after replacement with a non-consumable file" do
      product_file = build(:non_readable_document)
      media_location = MediaLocation.new(
        product_file:,
        location: 42,
        unit: MediaLocation::Unit::PERCENTAGE,
        epub_cfi: "epubcfi(/6/4!/4/2/8:0)",
        consumed_at: Time.current
      )

      expect(product_file.media_location_compatible?(media_location)).to be(false)
    end
  end

  describe "#must_be_pdf_stamped?" do
    it "returns false for a non-pdf file" do
      product_file = create(:non_readable_document)

      expect(product_file.must_be_pdf_stamped?).to eq(false)
    end

    it "returns false for a pdf file with pdf stamping disabled" do
      product_file = create(:readable_document, pdf_stamp_enabled: false)

      expect(product_file.must_be_pdf_stamped?).to eq(false)
    end

    it "returns false for a pdf file with pdf stamping enabled" do
      product_file = create(:readable_document, pdf_stamp_enabled: true)

      expect(product_file.must_be_pdf_stamped?).to eq(true)
    end
  end

  describe "#archivable?" do
    it "returns true only for archivable files" do
      archivable = [
        create(:readable_document),
        create(:non_streamable_video),
        create(:streamable_video),
        create(:non_readable_document),
        create(:listenable_audio)
      ]
      non_archivable = [
        create(:streamable_video, stream_only: true),
        # Downloads are off, so the file must not reach the buyer inside an archive.
        create(:readable_document, stream_only: true),
        create(:product_file, filetype: "link", url: "http://gumroad.com")
      ]

      expect(archivable.all?(&:archivable?)).to eq(true)
      expect(non_archivable.any?(&:archivable?)).to eq(false)
    end
  end

  describe "#stream_only?" do
    it "returns false for a readable document that is not marked as stream_only" do
      product_file = create(:readable_document)

      expect(product_file.stream_only?).to eq(false)
    end

    it "returns false for non-streamable video file" do
      product_file = create(:non_streamable_video)

      expect(product_file.stream_only?).to eq(false)
    end

    it "returns false for streamable video file not marked as stream_only" do
      product_file = create(:streamable_video)

      expect(product_file.stream_only?).to eq(false)
    end

    it "returns true for streamable video file marked as stream_only" do
      product_file = create(:streamable_video, stream_only: true)

      expect(product_file.stream_only?).to eq(true)
    end

    it "returns true for a readable document marked as stream_only" do
      product_file = create(:readable_document, stream_only: true)

      expect(product_file.stream_only?).to eq(true)
    end

    it "returns true for an EPUB marked as stream_only" do
      product_file = create(:epub_product_file, stream_only: true, size: 1.megabyte)

      expect(product_file.stream_only?).to eq(true)
    end

    it "returns false for files with no other way to open them" do
      product_files = [
        create(:non_readable_document, stream_only: true),
        create(:listenable_audio, stream_only: true),
        # Too large for the in-browser reader, so the download has to stay.
        create(:epub_product_file, stream_only: true, size: 33.megabytes)
      ]

      expect(product_files.map(&:stream_only?)).to eq([false, false, false])
    end
  end

  describe "#as_json download-disable eligibility" do
    it "reports the same eligibility the download gate uses" do
      expect(create(:epub_product_file, stream_only: true, size: 33.megabytes).as_json).to include(can_disable_downloads: false)
      expect(create(:readable_document).as_json).to include(can_disable_downloads: true)
      expect(create(:streamable_video).as_json).to include(can_disable_downloads: true)
    end
  end

  describe "file group and analyze" do
    it "enqueues analyze after file creation" do
      product_file = create(:readable_document)
      expect(AnalyzeFileWorker).to have_enqueued_sidekiq_job(product_file.id, ProductFile.name)
      expect(product_file.reload.pdf?).to be(true)
    end

    it "allows file size larger than max int" do
      product_file = create(:readable_document, size: 10_000_000_000)
      expect(product_file.reload.size).to eq 10_000_000_000
    end

    context "external link as a file" do
      it "skips analyze" do
        create(:product_file, filetype: "link", url: "https://www.gumroad.com")

        expect(AnalyzeFileWorker.jobs.size).to eq(0)
      end

      it "detects correct file group" do
        product_file = create(:product_file, filetype: "link", url: "https://www.gumroad.com")
        expect(product_file.filegroup).to eq("link")
      end

      it "returns the URL as the name of the file if it is blank" do
        product_file = create(:product_file, filetype: "link", url: "https://www.gumroad.com")
        expect(product_file.display_name).to be_nil
        expect(product_file.name_displayable).to eq(product_file.url)
      end
    end

    it "preserves s3 key for files containing percent and ampersand in filename" do
      product_file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/test file %26 & ) %29.txt")
      expect(product_file.s3_key).to eq "specs/test file %26 & ) %29.txt"
    end

    it "saves subtitle files correctly" do
      product_file = create(:product_file)
      subtitle_data = [
        {
          "language" => "English",
          "url" => "english.vtt"
        },
        {
          "language" => "Français",
          "url" => "french.vtt"
        },
        {
          "language" => "Español",
          "url" => "spanish.vtt"
        }
      ]
      product_file.save_subtitle_files!(subtitle_data)
      product_file.subtitle_files.each do |file|
        expect(file.language).to eq subtitle_data.find { _1["url"] == file.url }["language"]
      end
    end

    it "deletes all subtitle files correctly" do
      product_file = create(:product_file)
      subtitle_file = create(:subtitle_file, product_file:)
      product_file.subtitle_files.append(subtitle_file)
      product_file.delete_all_subtitle_files!
      expect(product_file.subtitle_files.alive.length).to eq 0
    end

    it "handles edits to subtitle files correctly" do
      product_file = create(:product_file)
      subtitle_file = create(:subtitle_file, product_file:)
      product_file.subtitle_files.append(subtitle_file)
      subtitle_file = create(:subtitle_file, url: "french.vtt", product_file:)
      product_file.subtitle_files.append(subtitle_file)
      subtitle_data = [
        {
          "language" => "Français",
          "url" => "french.vtt"
        },
        {
          "language" => "Español",
          "url" => "spanish.vtt"
        }
      ]
      product_file.save_subtitle_files!(subtitle_data)
      product_file.subtitle_files.alive.each do |file|
        expect(file.language).to eq subtitle_data.find { _1["url"] == file.url }["language"]
      end
      expect(product_file.subtitle_files.alive.length).to eq 2
    end

    describe "invalid file urls" do
      it "does not create files with invalid urls" do
        invalid_product_file = build(:product_file, url: "undefined")
        expect(invalid_product_file).to_not be_valid
        invalid_product_file.save
        expect(invalid_product_file.errors.full_messages.first).to eq "Please provide a valid file URL."
      end

      it "does not create files with invalid external links" do
        invalid_product_file = build(:product_file, url: "gum.road", filetype: "link")
        expect(invalid_product_file.valid?).to eq(false)
        expect(invalid_product_file.errors.full_messages).to include("gum.road is not a valid URL.")
      end
    end

    describe "renaming" do
      before do
        @product_file = create(:readable_document)
      end

      it "schedules renaming of S3 file if display_name updated" do
        @product_file.update!(description: "chapter one of the book")
        expect(RenameProductFileWorker).to_not have_enqueued_sidekiq_job(@product_file.id)

        @product_file.update!(display_name: "trillion-dollar-company")
        expect(RenameProductFileWorker).to have_enqueued_sidekiq_job(@product_file.id)
      end

      it "does not schedule rename in S3 if display_name updated for an external link file" do
        product_file = create(:product_file, filetype: "link", url: "https://gumroad.com")
        product_file.update!(display_name: "trillion-dollar-company")
        expect(RenameProductFileWorker).to_not have_enqueued_sidekiq_job(product_file.id)
      end

      it "renames files and preserves the Content-Type", :sidekiq_inline do
        expect(MultipartTransfer).to receive(:transfer_to_s3).with(/billion-dollar-company-chapter-0.pdf/,
                                                                   destination_filename: "dog.pdf",
                                                                   existing_s3_object: instance_of(@product_file.s3_object.class)).and_call_original

        @product_file.update!(display_name: "dog")
        @product_file.reload

        expect(@product_file.url).to match %r(attachments/[a-f\d]{32}/original/dog.pdf)
        expect(@product_file.name_displayable).to eq("dog")
        expect(@product_file.s3_object.content_type).to eq("application/pdf") # Assert content type of the old S3 object
        Rails.cache.delete("s3_key_ProductFile_#{@product_file.id}") # Clear the old cached s3_key
        expect(@product_file.s3_object.content_type).to eq("application/pdf") # Assert content type of the new S3 object
      end

      it "renames a file to a long name", :sidekiq_inline do
        new_name = "A" * 250
        expect(MultipartTransfer).to receive(:transfer_to_s3).with(/billion-dollar-company-chapter-0.pd/,
                                                                   destination_filename: "#{new_name}.pdf",
                                                                   existing_s3_object: instance_of(@product_file.s3_object.class)).and_call_original

        @product_file.update!(display_name: new_name)
        @product_file.reload

        expect(@product_file.url).to match %r(attachments/[a-f\d]{32}/original/#{new_name}.pdf)
        expect(@product_file.name_displayable).to eq(new_name)
      end
    end

    describe "a file stored without an extension" do
      def fixture_bytes(name)
        File.binread(Rails.root.join("spec/support/fixtures", name))
      end

      def mobi_bytes
        "Synthetic Mobi".ljust(32, "\0") + ("\0" * 28) + "BOOKMOBI" + ("\0" * 100)
      end

      def stored_without_extension(bytes, **attributes)
        key = "attachments/#{SecureRandom.hex}/original/Synthetic Book"
        Aws::S3::Resource.new.bucket(S3_BUCKET).object(key).put(body: bytes)
        create(:product_file, url: "#{S3_BASE_URL}#{key}", **attributes)
      end

      def requested_ranges
        ranges = []
        allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_wrap_original do |method, *args, &block|
          ranges << args.first[:range]
          method.call(*args, &block)
        end
        ranges
      end

      it "is typed as a PDF from its bytes, so it can be read, sent to Kindle and stamped" do
        product_file = stored_without_extension(fixture_bytes("billion-dollar-company-chapter-0.pdf"))
        expect(product_file.filetype).to be_nil
        allow(ProductIndexingService).to receive(:perform).and_call_original
        expect(ProductIndexingService).to receive(:perform).with(product: product_file.link, action: "update", attributes_to_update: ["filetypes"], on_failure: :async)

        product_file.analyze
        product_file.reload

        expect(product_file).to have_attributes(filetype: "pdf", filegroup: "document", size: 111_237, pagelength: 6, display_extension: "PDF")
        expect(product_file.browser_readable?).to be(true)
        expect(product_file.can_send_to_kindle?).to be(true)
        product_file.update!(pdf_stamp_enabled: true)
        expect(product_file.must_be_pdf_stamped?).to be(true)
      end

      it "checks a stamp-enabled PDF can be stamped once typed" do
        product_file = stored_without_extension(fixture_bytes("billion-dollar-company-chapter-0.pdf"), pdf_stamp_enabled: true)

        freeze_time do
          product_file.analyze

          expect(PdfUnstampableNotifierJob).to have_enqueued_sidekiq_job(product_file.link_id).in(5.seconds)
        end
        PdfUnstampableNotifierJob.drain
        expect(product_file.reload.stampable_pdf).to be(true)
        expect(BackfillPdfStampsJob.jobs.map { _1["args"] }).to eq([[product_file.link_id]])
      end

      it "keeps its type when renamed to a name with a dot", :sidekiq_inline do
        product_file = stored_without_extension(fixture_bytes("billion-dollar-company-chapter-0.pdf"), display_name: "Synthetic Book")
        product_file.analyze

        product_file.update!(display_name: "Synthetic Book Vol. 2")

        expect(product_file.reload).to have_attributes(filetype: "pdf", s3_filename: "Synthetic Book Vol. 2.pdf")
      end

      it "gives the detected extension to the names it hands out" do
        product_file = stored_without_extension(fixture_bytes("billion-dollar-company-chapter-0.pdf"))

        product_file.analyze

        expect(product_file.reload.mobile_json_data[:name]).to eq("Synthetic Book.pdf")
        expect(CGI.unescape(product_file.signed_url)).to include('filename="Synthetic Book.pdf"')
      end

      def put_object(bytes, name)
        key = "attachments/#{SecureRandom.hex}/original/#{name}"
        Aws::S3::Resource.new.bucket(S3_BUCKET).object(key).put(body: bytes)
        "#{S3_BASE_URL}#{key}"
      end

      it "stays a stamped PDF when a re-upload of the same bytes without an extension reuses it" do
        bytes = fixture_bytes("billion-dollar-company-chapter-0.pdf")
        product = create(:product)
        product_file = create(:product_file, link: product, url: put_object(bytes, "Book.pdf"), size: bytes.bytesize, pdf_stamp_enabled: true)
        retried_url = put_object(bytes, "Book")
        AnalyzeFileWorker.jobs.clear

        product.save_files!([{ external_id: SecureRandom.uuid, url: retried_url, size: bytes.bytesize }], delete_missing: false)

        expect(product_file.reload).to have_attributes(url: retried_url, filetype: "pdf")
        expect(product_file.must_be_pdf_stamped?).to be(true)
        expect(AnalyzeFileWorker.jobs.map { _1["args"] }).to eq([[product_file.id, "ProductFile"]])
        product_file.analyze
        expect(product_file.reload).to have_attributes(filetype: "pdf", filename_with_extension: "Book.pdf")
      end

      it "stays a stream-only video when a re-upload of the same bytes without an extension reuses it" do
        bytes = fixture_bytes("small.m4v")
        product = create(:product)
        product_file = create(:product_file, link: product, url: put_object(bytes, "Lesson.m4v"), size: bytes.bytesize, stream_only: true)
        allow(FFMPEG::Movie).to receive(:new).and_return(double(frame_rate: 60, duration: 13, width: 320, height: 240, bitrate: 125_779))

        retried_url = put_object(bytes, "Lesson")

        product.save_files!([{ external_id: SecureRandom.uuid, url: retried_url, size: bytes.bytesize }], delete_missing: false)
        expect(product_file.reload.url).to eq(retried_url)
        product_file.analyze

        expect(product_file.reload).to have_attributes(filetype: "m4v", filegroup: "video")
        expect(product_file.stream_only?).to be(true)
      end

      it "is typed from its new bytes when its url moves to a key without an extension" do
        product_file = create(:product_file, url: put_object("Synthetic notes", "notes.txt"))

        product_file.update!(url: put_object(fixture_bytes("billion-dollar-company-chapter-0.pdf"), "Synthetic Book"))
        product_file.analyze

        expect(product_file.reload).to have_attributes(filetype: "pdf", filename_with_extension: "Synthetic Book.pdf")
      end

      it "is not analyzed again when its url keeps an extension or does not change" do
        product_file = create(:product_file, url: put_object("Synthetic notes", "notes.txt"))
        AnalyzeFileWorker.jobs.clear

        product_file.update!(description: "Synthetic description")
        product_file.update!(url: put_object("Synthetic notes", "notes-2.txt"))

        expect(AnalyzeFileWorker.jobs.size).to eq(0)
      end

      # v2 API clients must echo the stored url to update a file, so typing must not move the object.
      it "keeps its stored url once typed", :sidekiq_inline do
        product_file = stored_without_extension(fixture_bytes("billion-dollar-company-chapter-0.pdf"), display_name: "Synthetic Book")
        stored_url = product_file.url

        product_file.analyze

        expect(product_file.reload).to have_attributes(filetype: "pdf", url: stored_url)
      end

      {
        "an EPUB" => [-> { fixture_bytes("test.epub") }, { filetype: "epub", filegroup: "document", pagelength: 13, display_extension: "EPUB" }],
        "a MOBI" => [-> { mobi_bytes }, { filetype: "mobi", filegroup: "document", display_extension: "MOBI" }],
        "a PNG" => [-> { fixture_bytes("kFDzu.png") }, { filetype: "png", filegroup: "image", width: 1633, height: 512, display_extension: "PNG" }],
        "a JPEG" => [-> { fixture_bytes("test-small.jpg") }, { filetype: "jpg", filegroup: "image", width: 25, height: 25, display_extension: "JPG" }],
        "a GIF" => [-> { fixture_bytes("test-small.gif") }, { filetype: "gif", filegroup: "image", width: 25, height: 25, display_extension: "GIF" }],
      }.each do |description, (bytes, expected)|
        it "is typed as #{description} from its bytes" do
          product_file = stored_without_extension(instance_exec(&bytes))

          product_file.analyze

          expect(product_file.reload).to have_attributes(expected)
        end
      end

      it "can read an EPUB and send it to Kindle once typed" do
        product_file = stored_without_extension(fixture_bytes("test.epub"))

        product_file.analyze
        product_file.reload

        expect(product_file.browser_readable?).to be(true)
        expect(product_file.can_send_to_kindle?).to be(true)
      end

      {
        "plain text" => -> { "Synthetic notes that mention no file format." },
        "a ZIP archive" => -> { fixture_bytes("test.zip") },
        "an MP3" => -> { fixture_bytes("magic.mp3") },
      }.each do |description, bytes|
        it "leaves #{description} untyped, reading only its leading bytes" do
          content = instance_exec(&bytes)
          product_file = stored_without_extension(content)
          ranges = requested_ranges

          expect { product_file.analyze }.not_to raise_error

          expect(product_file.reload).to have_attributes(filetype: nil, filegroup: nil, size: content.bytesize, display_extension: "")
          expect(ranges).to eq(["bytes=0-#{ProductFile::CONTENT_SNIFF_BYTES - 1}"])
        end
      end

      it "does not read an empty file" do
        product_file = stored_without_extension("")
        ranges = requested_ranges

        product_file.analyze

        expect(product_file.reload).to have_attributes(filetype: nil, size: 0)
        expect(ranges).to be_empty
      end

      it "is typed from its bytes only when the stored name has no extension" do
        bytes = fixture_bytes("billion-dollar-company-chapter-0.pdf")
        key = "attachments/#{SecureRandom.hex}/original/notes.txt"
        Aws::S3::Resource.new.bucket(S3_BUCKET).object(key).put(body: bytes)
        named_file = create(:product_file, url: "#{S3_BASE_URL}#{key}")
        unnamed_file = stored_without_extension(bytes)
        ranges = requested_ranges

        named_file.analyze
        unnamed_file.analyze

        expect(named_file.reload).to have_attributes(filetype: "txt", display_extension: "TXT")
        expect(unnamed_file.reload).to have_attributes(filetype: "pdf", display_extension: "PDF")
        expect(ranges).to eq(["bytes=0-#{ProductFile::CONTENT_SNIFF_BYTES - 1}", nil])
      end

      describe "ZIP archives" do
        let(:pdf_bytes) { fixture_bytes("billion-dollar-company-chapter-0.pdf") }

        def run_archive_jobs
          allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
          GenerateProductFilesArchivesJob.drain
          UpdateProductFilesArchiveWorker.drain
        ensure
          allow(Rails).to receive(:env).and_call_original
        end

        def zip_entries(archive)
          body = Aws::S3::Client.new.get_object(bucket: S3_BUCKET, key: archive.s3_key).body.read
          names = []
          Zip::File.open_buffer(body) { |zip| zip.each { names << _1.name.force_encoding("UTF-8") } }
          names.sort
        end

        def product_with_folder(*files)
          folder_id = SecureRandom.uuid
          create(:rich_content, entity: files.first.link, description: [
                   { "type" => "fileEmbedGroup", "attrs" => { "name" => "Folder", "uid" => folder_id }, "content" => files.map do |file|
                     { "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
                   end }])
          Link.find(files.first.link_id).generate_product_files_archives!
          run_archive_jobs
          folder_id
        end

        it "adds a file typed from its bytes to the product's folder ZIP, without serving the stale one meanwhile" do
          product = create(:product)
          book = create(:product_file, link: product, url: put_object(pdf_bytes, "Synthetic Book"), display_name: "Synthetic Book")
          notes = create(:product_file, link: product, url: put_object("Synthetic notes", "notes.txt"), display_name: "notes")
          folder_id = product_with_folder(book, notes)
          url_redirect = create(:url_redirect, link: product, purchase: create(:purchase, link: product))
          stale_archive = url_redirect.folder_archive(folder_id)
          expect(zip_entries(stale_archive)).to eq(["notes.txt"])

          book.reload.analyze

          expect(stale_archive.reload).to be_deleted
          expect(GenerateProductFilesArchivesJob.jobs.map { _1["args"] }).to eq([[product.id]])
          expect(url_redirect.reload.folder_archive(folder_id)).to be_nil
          run_archive_jobs
          expect(zip_entries(url_redirect.reload.folder_archive(folder_id))).to eq(["Synthetic Book.pdf", "notes.txt"])
        end

        it "adds a file typed from its bytes to an installment's ZIP" do
          installment = create(:installment)
          book = create(:product_file, link: nil, installment:, url: put_object(pdf_bytes, "Synthetic Book"), display_name: "Synthetic Book")
          create(:product_file, link: nil, installment:, url: put_object("Synthetic notes", "notes.txt"), display_name: "notes")
          installment.generate_entity_archive!
          run_archive_jobs
          stale_archive = installment.product_files_archives.latest_ready_entity_archive
          expect(zip_entries(stale_archive)).to eq(["notes.txt"])

          book.reload.analyze

          expect(stale_archive.reload).to be_deleted
          run_archive_jobs
          expect(zip_entries(installment.product_files_archives.latest_ready_entity_archive)).to eq(["Synthetic Book.pdf", "notes.txt"])
        end

        it "keeps ZIPs when analyze detects no new type" do
          product = create(:product)
          typed_book = create(:product_file, link: product, url: put_object(pdf_bytes, "Synthetic Book"), display_name: "Synthetic Book")
          typed_book.analyze
          unknown = create(:product_file, link: product, url: put_object(fixture_bytes("test.zip"), "Synthetic Archive"), display_name: "Synthetic Archive")
          notes = create(:product_file, link: product, url: put_object("Synthetic notes", "notes.txt"), display_name: "notes")
          folder_id = product_with_folder(typed_book, unknown, notes)
          archive = create(:url_redirect, link: product, purchase: create(:purchase, link: product)).folder_archive(folder_id)
          GenerateProductFilesArchivesJob.jobs.clear

          [typed_book, unknown, notes].each { _1.reload.analyze }

          expect(archive.reload).to have_attributes(deleted?: false, product_files_archive_state: "ready")
          expect(GenerateProductFilesArchivesJob.jobs.size).to eq(0)
          expect(zip_entries(archive)).to eq(["Synthetic Book.pdf", "notes.txt"])
        end

        it "keeps the digest of names that have their own extension, and adds the detected one" do
          product = create(:product)
          notes = create(:product_file, link: product, url: put_object("Synthetic notes", "notes.txt"), display_name: "notes")
          book = create(:product_file, link: product, url: put_object(pdf_bytes, "Synthetic Book"), display_name: "Synthetic Book")
          book.analyze
          archive = product.product_files_archives.new

          expect(archive.digest_for_files([notes])).to eq(Digest::SHA1.hexdigest("#{notes.external_id}/notes"))
          expect(archive.digest_for_files([book.reload])).to eq(Digest::SHA1.hexdigest("#{book.external_id}/Synthetic Book.pdf"))
        end
      end
    end

    it "creates the product file with filetype set to lowercase" do
      product_file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/fc34ee33bae54181badd048c71209d24/original/sample.PDF")
      expect(product_file.filetype).to eq("pdf")
    end
  end

  describe "product file for installments" do
    it "schedules analyze and not schedule PdfUnstampableNotifierJob if the file belongs to an installment" do
      product_file = create(:readable_document, link: nil, installment: create(:installment))
      expect(AnalyzeFileWorker).to have_enqueued_sidekiq_job(product_file.id, ProductFile.name)
      expect(PdfUnstampableNotifierJob.jobs.size).to eq(0)
    end
  end

  describe "#transcodable?" do
    let(:product_file) do
      create(:streamable_video, width: 2550, height: 1750, bitrate: 869_480)
    end

    it "returns `false` if the width is not set" do
      product_file.update!(width: nil)

      expect(product_file.transcodable?).to be(false)
    end

    it "returns `false` if the height is not set" do
      product_file.update!(height: nil)

      expect(product_file.transcodable?).to be(false)
    end

    it "returns `false` if the file is not a video file" do
      expect(product_file).to receive(:streamable?).and_return(false)

      expect(product_file.transcodable?).to be(false)
    end

    it "returns `true` if the dimensions are set for a video file" do
      expect(product_file.transcodable?).to be(true)
    end
  end

  describe "#transcoding_in_progress?" do
    it "returns true if there's a transcoded video in progress" do
      product = create(:product_with_video_file)
      video_file = product.product_files.first
      expect(video_file.transcoding_in_progress?).to eq(false)
      create(:transcoded_video, streamable: video_file, original_video_key: video_file.s3_key, state: "processing")
      expect(video_file.reload.transcoding_in_progress?).to eq(true)
    end
  end

  describe "#transcoding_failed" do
    it "sends an email to the creator" do
      product_file = create(:product_file)

      expect { product_file.transcoding_failed }
        .to have_enqueued_mail(ContactingCreatorMailer, :video_transcode_failed).with(product_file.id)
    end
  end

  describe "#attempt_to_transcode?" do
    let(:product_file) do
      create(:streamable_video, width: 2550, height: 1750, bitrate: 869_480)
    end

    it "returns `false` if there are transcoding jobs in the 'processing' state" do
      create(:transcoded_video, streamable: product_file, original_video_key: product_file.s3_key, state: "processing")

      expect(product_file.attempt_to_transcode?).to be(false)
    end

    it "with allowed_when_processing=true returns `true` if there are transcoding jobs in the 'processing' state" do
      create(:transcoded_video, streamable: product_file, original_video_key: product_file.s3_key, state: "processing")

      expect(product_file.attempt_to_transcode?(allowed_when_processing: true)).to be(true)
    end

    it "returns `false` if there are transcoding jobs in the 'completed' state" do
      create(:transcoded_video, streamable: product_file, original_video_key: product_file.s3_key, state: "completed")

      expect(product_file.attempt_to_transcode?).to be(false)
    end

    it "returns `true` if the there are no 'processing' or 'completed' transcoding jobs" do
      expect(product_file.attempt_to_transcode?).to be(true)
    end
  end

  describe "s3 properties" do
    before do
      @product_file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/files/43a5363194e74e9ee75b6203eaea6705/original/black/white.mp4")
    end

    it "handles / in the filename properly" do
      expect(@product_file.s3_key).to eq("files/43a5363194e74e9ee75b6203eaea6705/original/black/white.mp4")
      expect(@product_file.s3_filename).to eq("black/white.mp4")
      expect(@product_file.s3_display_name).to eq("black/white")
      expect(@product_file.s3_extension).to eq(".mp4")
      expect(@product_file.s3_display_extension).to eq("MP4")
    end

    it "works as expected for files without an extension" do
      @product_file.update!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/files/43a5363194e74e9ee75b6203eaea6705/original/black/white")

      expect(@product_file.s3_key).to eq("files/43a5363194e74e9ee75b6203eaea6705/original/black/white")
      expect(@product_file.s3_filename).to eq("black/white")
      expect(@product_file.s3_display_name).to eq("black/white")
      expect(@product_file.s3_extension).to eq("")
      expect(@product_file.s3_display_extension).to eq("")
    end

    it "reads the file name when the key is namespaced by the owning seller's external id" do
      @product_file.update!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/#{@product_file.user.external_id}/43a5363194e74e9ee75b6203eaea6705/original/black/white.mp4")

      expect(@product_file.s3_filename).to eq("black/white.mp4")
    end

    # A collaborator's uploads are namespaced by their own external id, not the product owner's.
    it "reads the file name when the key is namespaced by another account's external id" do
      collaborator = create(:user)
      @product_file.update!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/#{collaborator.external_id}/43a5363194e74e9ee75b6203eaea6705/original/black/white.mp4")

      expect(@product_file.s3_filename).to eq("black/white.mp4")
    end
  end

  describe "#delete!" do
    it "deletes all associated subtitle files for an mp4 file" do
      mp4_file = create(:product_file)
      subtitle_file = create(:subtitle_file, product_file: mp4_file)
      mp4_file.subtitle_files.append(subtitle_file)
      subtitle_file = create(:subtitle_file, url: "french.vtt", product_file: mp4_file)
      mp4_file.subtitle_files.append(subtitle_file)
      expect(mp4_file.subtitle_files.alive.size).to eq(2)

      mp4_file.delete!
      expect(mp4_file.reload.deleted_at).not_to be(nil)
      expect(mp4_file.subtitle_files.alive.size).to eq(0)
      mp4_file.subtitle_files.each do |file|
        expect(file.deleted_at).not_to be(nil)
      end
    end
  end

  describe "#hls_playlist" do
    before do
      @multifile_product = create(:product)
      @file_1 = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter 2.mp4", is_transcoded_for_hls: true)
      @multifile_product.product_files << @file_1
      @transcoded_video = create(:transcoded_video, link: @multifile_product, streamable: @file_1, original_video_key: @file_1.s3_key,
                                                    transcoded_video_key: "attachments/2_1/original/chapter 2/hls/index.m3u8",
                                                    is_hls: true, state: "completed")

      s3_new = double("s3_new")
      s3_bucket = double("s3_bucket")
      s3_object = double("s3_object")
      hls = "#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=854x480,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=1191000\nhls_480p_.m3u8\n"
      hls += "#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=1280x720,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=2805000\nhls_720p_.m3u8\n"
      allow(Aws::S3::Resource).to receive(:new).and_return(s3_new)
      allow(s3_new).to receive(:bucket).and_return(s3_bucket)
      allow(s3_bucket).to receive(:object).and_return(s3_object)
      allow(s3_object).to receive(:get).and_return(double(body: double(read: hls)))
    end

    it "replaces the links to the playlists with signed urls" do
      travel_to(Date.parse("2015-03-13")) do
        hls_playlist = @file_1.hls_playlist
        url = "#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=854x480,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=1191000\n"
        url += "https://d1jmbc8d0c0hid.cloudfront.net/attachments/2_1/original/chapter+2/hls/hls_480p_.m3u8?Expires=1426248000&"
        url += "Signature=lqqrPpAOP6KeFxLiOt/ynEpMvkAgIzwuQM9LZSA6cB143fSP0WVkGuq10VJzsICzQ/3wdSWhRYTgJsNQMATDtg==&"
        url += "Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n"
        url += "#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=1280x720,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=2805000\n"
        url += "https://d1jmbc8d0c0hid.cloudfront.net/attachments/2_1/original/chapter+2/hls/hls_720p_.m3u8?Expires=1426248000&"
        url += "Signature=P3ocRbRxhWiP1pSWehzxz7PMx+GUlhoZGL5u+KMIj4+hrbcoT3Gm9rNiZL1PDUzBHP6DJ8Cgw3TNPYb2xcoNsQ==&"
        url += "Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n"
        expect(hls_playlist).to eq url
      end
    end

    it "escapes the user-provided filename even if the user has changed the filename since the video was transcoded" do
      @file_1.update!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter_2_no_spaces.mp4")
      travel_to(Date.parse("2015-03-13")) do
        hls_playlist = @file_1.hls_playlist
        url = "#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=854x480,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=1191000\n"
        url += "https://d1jmbc8d0c0hid.cloudfront.net/attachments/2_1/original/chapter+2/hls/hls_480p_.m3u8?Expires=1426248000&" # Notice the + in chapter+2
        url += "Signature=lqqrPpAOP6KeFxLiOt/ynEpMvkAgIzwuQM9LZSA6cB143fSP0WVkGuq10VJzsICzQ/3wdSWhRYTgJsNQMATDtg==&"
        url += "Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n"
        url += "#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=1280x720,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=2805000\n"
        url += "https://d1jmbc8d0c0hid.cloudfront.net/attachments/2_1/original/chapter+2/hls/hls_720p_.m3u8?Expires=1426248000&" # Notice the + in chapter+2
        url += "Signature=P3ocRbRxhWiP1pSWehzxz7PMx+GUlhoZGL5u+KMIj4+hrbcoT3Gm9rNiZL1PDUzBHP6DJ8Cgw3TNPYb2xcoNsQ==&"
        url += "Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n"
        expect(hls_playlist).to eq url
      end
    end

    it "escapes the filename in legacy S3 attachments" do
      file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/0000134abcdefghhijkl354sfdg/chapter 2.mp4", is_transcoded_for_hls: true)
      @multifile_product.product_files << file
      @transcoded_video = create(:transcoded_video, link: @multifile_product, streamable: file, original_video_key: file.s3_key,
                                                    transcoded_video_key: "attachments/0000134abcdefghhijkl354sfdg/chapter 2/hls/index.m3u8",
                                                    is_hls: true, state: "completed")
      expect(file.hls_playlist).to include("attachments/0000134abcdefghhijkl354sfdg/chapter+2/hls/hls_480p_.m3u8")
    end

    it "returns nil when the S3 playlist object does not exist" do
      s3_object = double("s3_object")
      allow(s3_object).to receive(:get).and_raise(Aws::S3::Errors::NoSuchKey.new(nil, "The specified key does not exist."))
      s3_bucket = double("s3_bucket")
      allow(s3_bucket).to receive(:object).and_return(s3_object)
      s3_resource = double("s3_resource")
      allow(s3_resource).to receive(:bucket).and_return(s3_bucket)
      allow(Aws::S3::Resource).to receive(:new).and_return(s3_resource)

      expect(@file_1.hls_playlist).to be_nil
    end

    it "escapes the newlines in the filename" do
      file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/12345/abcd12345/original/YouTube + Marketing Is Powerful\n.mp4", is_transcoded_for_hls: true)
      @multifile_product.product_files << file
      @transcoded_video = create(:transcoded_video, link: @multifile_product, streamable: file, original_video_key: file.s3_key,
                                                    transcoded_video_key: "attachments/12345/abcd12345/original/YouTube + Marketing Is Powerful\n/hls/index.m3u8",
                                                    is_hls: true, state: "completed")
      expect(file.hls_playlist).to include("attachments/12345/abcd12345/original/YouTube+%2B+Marketing+Is+Powerful%0A/hls/hls_720p_.m3u8")
    end
  end

  describe "#subtitle_files_for_mobile" do
    let(:product_file) { create(:product_file) }

    context "when there are no alive subtitle files associated" do
      it "returns an empty array" do
        expect(product_file.subtitle_files_for_mobile).to eq([])
      end
    end

    context "when associated alive subtitle files exist" do
      let(:english_srt_url) { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/english.srt" }
      let(:french_srt_url) { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/french.srt" }
      let(:subtitle_file_en) do
        create(:subtitle_file, language: "English", url: english_srt_url, product_file:)
      end
      let(:subtitle_file_fr) do
        create(:subtitle_file, language: "Français", url: french_srt_url, product_file:)
      end
      let(:subtitle_file_de) do
        create(:subtitle_file, language: "Deutsch", product_file:, deleted_at: Time.current)
      end

      before do
        # Stub URLs to be returned as the process to do the actual computation makes S3 calls and such
        allow_any_instance_of(SignedUrlHelper).to(
          receive(:signed_download_url_for_s3_key_and_filename)
            .with(subtitle_file_en.s3_key, subtitle_file_en.s3_filename, is_video: true).and_return(english_srt_url))
        allow_any_instance_of(SignedUrlHelper).to(
          receive(:signed_download_url_for_s3_key_and_filename)
            .with(subtitle_file_fr.s3_key, subtitle_file_fr.s3_filename, is_video: true).and_return(french_srt_url))
      end

      it "returns url and language for all the files" do
        expected_result = [
          { url: english_srt_url, language: "English" },
          { url: french_srt_url, language: "Français" }
        ]
        expect(product_file.subtitle_files_for_mobile).to match_array(expected_result)
      end
    end
  end

  describe "mobile" do
    before do
      @file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter 2.mp4", is_transcoded_for_hls: true)
    end

    it "returns name values that contain extensions" do
      expect(@file.mobile_json_data[:name]).to eq "chapter 2.mp4"
    end

    it "returns name_displayable" do
      display_name = @file.mobile_json_data[:name_displayable]
      expect(display_name).to eq @file.name_displayable
    end
  end

  describe "#external_folder_id" do
    before do
      @folder = create(:product_folder)
      @file = create(:product_file, link: @folder.link, folder: @folder)
    end

    it "returns external id if folder exists" do
      expect(@file.external_folder_id).to eq(@folder.external_id)
    end

    it "returns nil if folder does not exist" do
      file = create(:product_file)
      expect(file.external_folder_id).to eq(nil)
    end

    it "returns nil if folder is hard deleted" do
      expect do
        @folder.delete
      end.to change { @file.reload.external_folder_id }.from(@folder.external_id).to(nil)
    end

    it "returns nil if folder is soft deleted" do
      expect do
        @folder.mark_deleted!
      end.to change { @file.reload.external_folder_id }.from(@folder.external_id).to(nil)
    end
  end

  describe "#has_cdn_url?" do
    it "returns a truthy value when the CDN URL is in a specific format" do
      product_file = create(:product_file)

      expect(product_file.has_cdn_url?).to be_truthy
    end

    it "returns a falsey value when the CDN URL is not in the regular Gumroad format" do
      product_file = build(:product_file, url: "https:/unknown.com/manual.pdf")

      expect(product_file.has_cdn_url?).to be_falsey
    end
  end

  describe "#has_valid_external_link?" do
    it "returns truthy value when url is valid" do
      test_urls = ["http://www.example.abc/test", "https://www.gumroad.com/product", "http://www.google.io/product"]
      test_urls.each do |test_url|
        product_file = build(:product_file, url: test_url)
        expect(product_file.has_valid_external_link?).to be_truthy
      end
    end

    it "returns falsey value when url is invalid" do
      test_urls = ["www.example.abc/test", "invalid_url", "ogle.io/product", "http:invalid", "http:/invalid"]
      test_urls.each do |test_url|
        product_file = build(:product_file, url: test_url)
        expect(product_file.has_valid_external_link?).to be_falsey
      end
    end
  end

  describe "#external_link?" do
    it "returns true for files which are external links" do
      product_file = create(:product_file, filetype: "link", url: "http://gumroad.com")
      expect(product_file.external_link?).to eq(true)
    end

    it "returns false for non-external link files" do
      product_file = create(:readable_document)
      expect(product_file.external_link?).to eq(false)
    end
  end

  describe "#stored_file_present?" do
    it "returns true without asking storage when the file has been analyzed" do
      product_file = create(:product_file, analyze_completed: true)
      expect(product_file).not_to receive(:s3_object)

      expect(product_file.stored_file_present?).to eq(true)
    end

    # `size` is accepted from the client by the product-save API, so it must not
    # be what lets a file skip the storage check.
    it "still asks storage for a never-analyzed file that claims a size" do
      product_file = create(:product_file, size: 1_024, analyze_completed: false)
      allow(product_file).to receive(:s3_object).and_return(double("s3_object", exists?: false))

      expect(product_file.stored_file_present?).to eq(false)
    end

    it "returns true for an external link, which has no storage object" do
      product_file = create(:external_link)
      expect(product_file).not_to receive(:s3_object)

      expect(product_file.stored_file_present?).to eq(true)
    end

    it "asks storage when the file has never been analyzed" do
      product_file = create(:product_file, analyze_completed: false)
      allow(product_file).to receive(:s3_object).and_return(double("s3_object", exists?: true))

      expect(product_file.stored_file_present?).to eq(true)
    end

    it "returns false when the upload never finished, so nothing was written" do
      product_file = create(:product_file, analyze_completed: false)
      allow(product_file).to receive(:s3_object).and_return(double("s3_object", exists?: false))

      expect(product_file.stored_file_present?).to eq(false)
    end

    it "returns false when the object has been purged from storage" do
      product_file = create(:product_file, analyze_completed: true, deleted_from_cdn_at: Time.current)

      expect(product_file.stored_file_present?).to eq(false)
    end

    it "returns true when storage can't be reached, since an outage isn't evidence the file is gone" do
      product_file = create(:product_file, analyze_completed: false)
      allow(product_file).to receive(:s3_object).and_raise(Aws::S3::Errors::ServiceUnavailable.new(nil, "unavailable"))

      expect(product_file.stored_file_present?).to eq(true)
    end

    # Proving the object is absent is the only moment we learn this row's upload
    # never finished, so the finding is handed to a job that records it on the row
    # — otherwise the next caller pays the same lookup for the same answer.
    it "asks for the row to be retired when the object is proved absent" do
      product_file = create(:product_file, analyze_completed: false)
      product_file.update_column(:created_at, RecordProductFileMissingFromStorageJob::UPLOAD_GRACE_PERIOD.ago - 1.day)
      allow(product_file).to receive(:s3_object).and_return(double("s3_object", exists?: false))

      expect do
        expect(product_file.stored_file_present?).to eq(false)
      end.to change { RecordProductFileMissingFromStorageJob.jobs.size }.by(1)
      expect(RecordProductFileMissingFromStorageJob.jobs.last["args"]).to eq([product_file.id])
    end

    # The row is still within the window where a large upload could be in
    # progress, so its absence proves nothing durable yet.
    it "does not ask for a row to be retired while its upload could still be in flight" do
      product_file = create(:product_file, analyze_completed: false)
      allow(product_file).to receive(:s3_object).and_return(double("s3_object", exists?: false))

      expect do
        expect(product_file.stored_file_present?).to eq(false)
      end.not_to change { RecordProductFileMissingFromStorageJob.jobs.size }
    end

    it "does not ask for a row to be retired when the file is really there" do
      product_file = create(:product_file, analyze_completed: false)
      product_file.update_column(:created_at, RecordProductFileMissingFromStorageJob::UPLOAD_GRACE_PERIOD.ago - 1.day)
      allow(product_file).to receive(:s3_object).and_return(double("s3_object", exists?: true))

      expect do
        expect(product_file.stored_file_present?).to eq(true)
      end.not_to change { RecordProductFileMissingFromStorageJob.jobs.size }
    end

    # An outage is not evidence the file is gone, so it must not retire the row
    # either.
    it "does not ask for a row to be retired when storage can't be reached" do
      product_file = create(:product_file, analyze_completed: false)
      product_file.update_column(:created_at, RecordProductFileMissingFromStorageJob::UPLOAD_GRACE_PERIOD.ago - 1.day)
      allow(product_file).to receive(:s3_object).and_raise(Aws::S3::Errors::ServiceUnavailable.new(nil, "unavailable"))

      expect do
        expect(product_file.stored_file_present?).to eq(true)
      end.not_to change { RecordProductFileMissingFromStorageJob.jobs.size }
    end

    # This runs inside a product validation, so a queueing problem must not turn
    # into a failed save for the seller.
    it "still answers the caller when the row can't be queued for retirement" do
      product_file = create(:product_file, analyze_completed: false)
      product_file.update_column(:created_at, RecordProductFileMissingFromStorageJob::UPLOAD_GRACE_PERIOD.ago - 1.day)
      allow(product_file).to receive(:s3_object).and_return(double("s3_object", exists?: false))
      allow(RecordProductFileMissingFromStorageJob).to receive(:perform_async).and_raise(Redis::CannotConnectError)

      expect(product_file.stored_file_present?).to eq(false)
    end

    # Redis being down is the expected reason to end up here and resolves on its
    # own, so it stays a log line. Alerting on it would page us for an outage we
    # already know about.
    it "does not report an unreachable queue" do
      product_file = create(:product_file, analyze_completed: false)
      product_file.update_column(:created_at, RecordProductFileMissingFromStorageJob::UPLOAD_GRACE_PERIOD.ago - 1.day)
      allow(product_file).to receive(:s3_object).and_return(double("s3_object", exists?: false))
      allow(RecordProductFileMissingFromStorageJob).to receive(:perform_async).and_raise(Redis::CannotConnectError)
      expect(ErrorNotifier).not_to receive(:notify)

      expect(product_file.stored_file_present?).to eq(false)
    end

    # Anything that isn't the queue being unreachable is a bug in how we enqueue.
    # It must still not fail the seller's save, but it has to be reported instead
    # of silently skipping retirement forever.
    it "reports an unexpected queueing failure without failing the caller" do
      product_file = create(:product_file, analyze_completed: false)
      product_file.update_column(:created_at, RecordProductFileMissingFromStorageJob::UPLOAD_GRACE_PERIOD.ago - 1.day)
      allow(product_file).to receive(:s3_object).and_return(double("s3_object", exists?: false))
      error = ArgumentError.new("Job arguments to RecordProductFileMissingFromStorageJob must be native JSON types")
      allow(RecordProductFileMissingFromStorageJob).to receive(:perform_async).and_raise(error)
      expect(ErrorNotifier).to receive(:notify).with(error, product_file_id: product_file.id)

      expect(product_file.stored_file_present?).to eq(false)
    end

    # Reporting is best-effort too: Sentry goes over the network and can fail on
    # its own, and this path runs inside a seller's save, so a failure to report
    # must not fail that save.
    it "still answers the caller when the queueing failure can't be reported" do
      product_file = create(:product_file, analyze_completed: false)
      product_file.update_column(:created_at, RecordProductFileMissingFromStorageJob::UPLOAD_GRACE_PERIOD.ago - 1.day)
      allow(product_file).to receive(:s3_object).and_return(double("s3_object", exists?: false))
      allow(RecordProductFileMissingFromStorageJob).to receive(:perform_async).and_raise(ArgumentError.new("bad argument"))
      allow(ErrorNotifier).to receive(:notify).and_raise(Errno::ECONNREFUSED)

      expect(product_file.stored_file_present?).to eq(false)
    end
  end

  describe "#stored_file_presence_known_from_row" do
    it "returns true for an analyzed file" do
      expect(create(:product_file, analyze_completed: true).stored_file_presence_known_from_row).to eq(true)
    end

    it "returns true for an external link" do
      expect(create(:external_link).stored_file_presence_known_from_row).to eq(true)
    end

    it "returns false for a file purged from storage" do
      product_file = create(:product_file, analyze_completed: true, deleted_from_cdn_at: Time.current)

      expect(product_file.stored_file_presence_known_from_row).to eq(false)
    end

    # This is the row a never-finished upload leaves behind: only storage can say
    # whether anything was written.
    it "returns nil for a never-analyzed file, which only storage can answer for" do
      expect(create(:product_file, analyze_completed: false).stored_file_presence_known_from_row).to be_nil
    end
  end

  describe "#display_extension" do
    it "returns URL for files which are external links" do
      product_file = create(:product_file, filetype: "link", url: "http://gumroad.com")
      expect(product_file.display_extension).to eq("URL")
    end

    it "returns extension for s3 files with an extension" do
      product_file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/files/43a5363194e74e9ee75b6203eaea6705/original/black/white.mp4")
      expect(product_file.display_extension).to eq("MP4")
    end

    it "returns empty string for s3 files without an extension" do
      product_file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/files/43a5363194e74e9ee75b6203eaea6705/original/black/white")
      expect(product_file.display_extension).to eq("")
    end
  end

  describe "#queue_for_transcoding" do
    it "returns `false` when both `streamable?` and `analyze_completed?` are `false`" do
      product_file = create(:product_file)
      product_file.update_columns(filegroup: "audio") # Need to bypass callbacks otherwise the value is overwritten

      expect(product_file.queue_for_transcoding?).to eq(false)
    end

    it "returns `false` when `streamable?` is `false` and `analyze_completed?` is `true`" do
      product_file = create(:product_file, analyze_completed: true)
      product_file.update_columns(filegroup: "audio") # Need to bypass callbacks otherwise the value is overwritten

      expect(product_file.queue_for_transcoding?).to eq(false)
    end

    it "returns `true` when both `streamable?` and `analyze_completed?` are `true`" do
      product_file = create(:product_file, analyze_completed: true)
      product_file.update_columns(filegroup: "video") # Need to bypass callbacks otherwise the value is overwritten

      expect(product_file.queue_for_transcoding?).to eq(true)
    end

    it "returns `false` when `streamable?` is `true` and `analyze_completed?` is `false`" do
      product_file = create(:product_file)
      product_file.update_columns(filegroup: "video") # Need to bypass callbacks otherwise the value is overwritten

      expect(product_file.queue_for_transcoding?).to eq(false)
    end
  end

  describe "#download_original" do
    it "returns original file as tempfile" do
      product_file = create(:readable_document)
      yielded = false
      product_file.download_original do |original_file|
        yielded = true
        expect(original_file.path).to include(".pdf")
        expect(original_file.size).to eq(111237)
      end
      expect(yielded).to eq(true)
    end
  end

  describe "#latest_media_location_for" do
    before do
      @url_redirect = create(:readable_url_redirect)
      @product_file = @url_redirect.referenced_link.product_files.first
    end

    it "returns nil if no media locations exist" do
      expect(@product_file.latest_media_location_for(@url_redirect.purchase)).to eq(nil)
    end

    it "returns nil if purchase does not exist" do
      expect(@product_file.latest_media_location_for(nil)).to eq(nil)
    end

    it "returns nil if product file belongs to an installment" do
      installment = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.gum.co", seller: create(:user))
      installment_product_file = create(:product_file, installment:, link: nil)
      installment_purchase = create(:purchase, link: installment.link)
      installment_url_redirect = installment.generate_url_redirect_for_purchase(installment_purchase)
      create(:media_location, url_redirect_id: installment_url_redirect.id, purchase_id: installment_purchase.id, platform: Platform::WEB,
                              product_file_id: installment_product_file.id, product_id: installment.link.id, location: 1, consumed_at: Time.current)
      expect(installment_product_file.latest_media_location_for(installment_purchase)).to eq(nil)
    end

    context "latest_media_location for different file types" do
      it "returns latest media location for readable" do
        consumption_timestamp = Time.current.change(usec: 0)
        create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id, platform: Platform::WEB,
                                product_file_id: @product_file.id, product_id: @url_redirect.referenced_link.id, location: 1, consumed_at: consumption_timestamp)
        expect(@product_file.latest_media_location_for(@url_redirect.purchase)).to eq({ location: 1, unit: MediaLocation::Unit::PAGE_NUMBER, timestamp: consumption_timestamp })
      end

      it "returns latest media location for streamable" do
        streamable_file = create(:streamable_video, link: @url_redirect.referenced_link)
        consumption_timestamp = Time.current.change(usec: 0)
        create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id, platform: Platform::WEB,
                                product_file_id: streamable_file.id, product_id: @url_redirect.referenced_link.id, location: 2, consumed_at: consumption_timestamp)
        expect(streamable_file.latest_media_location_for(@url_redirect.purchase)).to eq({ location: 2, unit: MediaLocation::Unit::SECONDS, timestamp: consumption_timestamp })
      end

      it "returns latest media location for listenable" do
        listenable_file = create(:listenable_audio, link: @url_redirect.referenced_link)
        consumption_timestamp = Time.current.change(usec: 0)
        create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id, platform: Platform::WEB,
                                product_file_id: listenable_file.id, product_id: @url_redirect.referenced_link.id, location: 10, consumed_at: consumption_timestamp)
        expect(listenable_file.latest_media_location_for(@url_redirect.purchase)).to eq({ location: 10, unit: MediaLocation::Unit::SECONDS, timestamp: consumption_timestamp })
      end
    end

    it "returns the location with latest timestamp if multiple media_locations exist" do
      consumption_timestamp = Time.current.change(usec: 0)
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product_file.id, product_id: @url_redirect.referenced_link.id, location: 1, consumed_at: consumption_timestamp)
      consumption_timestamp_2 = consumption_timestamp + 1.second
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id, platform: Platform::ANDROID,
                              product_file_id: @product_file.id, product_id: @url_redirect.referenced_link.id, location: 3, consumed_at: consumption_timestamp_2)
      expect(@product_file.latest_media_location_for(@url_redirect.purchase)).to eq({ location: 3, unit: MediaLocation::Unit::PAGE_NUMBER, timestamp: consumption_timestamp_2 })
    end
  end

  describe "thumbnail" do
    describe "validations" do
      it "marks invalid if the attached thumbnail is not an image" do
        product_file = create(:streamable_video)
        product_file.thumbnail.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "sample_doc.docx")), filename: "sample_doc.docx")

        expect(product_file).to be_invalid
        expect(product_file.errors.full_messages).to include("Please upload a thumbnail in JPG, PNG, or GIF format.")
      end

      it "marks invalid if the attached thumbnail is too large" do
        product_file = create(:streamable_video)
        product_file.thumbnail.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "P1110259.JPG")), filename: "P1110259.JPG")

        expect(product_file).to be_invalid
        expect(product_file.errors.full_messages).to include("Could not process your thumbnail, please upload an image with size smaller than 5 MB.")
      end

      it "is valid if the attached thumbnail is an image with size smaller than 5 MB" do
        product_file = create(:streamable_video)
        product_file.thumbnail.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")), filename: "smilie.png")

        expect(product_file).to be_valid
        expect(product_file.thumbnail_variant.url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{product_file.thumbnail_variant.key}")
      end
    end

    describe "#thumbnail_url" do
      it "returns nil if no thumbnail exists" do
        product_file = create(:readable_document)

        expect(product_file.thumbnail.attached?).to be(false)
        expect(product_file.thumbnail_url).to be_nil
      end

      it "returns the CDN URL if thumbnail exists" do
        stub_const("CDN_URL_MAP", { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}" => "https://public-files.gumroad.com" })

        product_file = create(:streamable_video)
        product_file.thumbnail.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")), filename: "smilie.png")

        expect(product_file.thumbnail_url).to match("https://public-files.gumroad.com/#{product_file.thumbnail_variant.key}")
      end

      it "returns a thumbnail for images a browser can draw, and none for other image formats" do
        png = create(:product_file, url: "#{S3_BASE_URL}specs/brick-albedo.png", filetype: "png", filegroup: "image")
        tga = create(:product_file, url: "#{S3_BASE_URL}specs/brick-height.tga", filetype: "tga", filegroup: "url")
        [png, tga].each { _1.thumbnail.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")), filename: "smilie.png") }

        expect(png.thumbnail_url).to be_present
        expect(tga.thumbnail_url).to be_nil
      end

      it "returns the original thumbnail URL when the thumbnail variant processing fails" do
        product_file = create(:streamable_video)
        product_file.thumbnail.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")), filename: "smilie.png")

        allow(product_file).to receive(:thumbnail_variant).and_raise(ActiveStorage::InvariableError)

        expect(product_file.thumbnail_url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{product_file.thumbnail.key}")
      end
    end

    describe "#thumbnail_variant" do
      it "returns the resized thumbnail variant" do
        product_file = create(:streamable_video)
        product_file.thumbnail.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")), filename: "smilie.png")

        expect(product_file.thumbnail.variant(resize_to_limit: [1280, 720]).send(:processed?)).to be(false)
        product_file.thumbnail_variant
        expect(product_file.thumbnail.variant(resize_to_limit: [1280, 720]).send(:processed?)).to be(true)
      end
    end
  end

  describe "isbn" do
    context "normalization" do
      it "converts em and en dashes to ASCII dash" do
        file = create(:pdf_product_file, isbn: "978–3—16−1484100")
        expect(file.isbn).to eq("978-3-16-1484100")
      end

      it "converts whitespaces to ASCII dash" do
        file = create(:pdf_product_file, isbn: "978 3 16 1484100")
        expect(file.isbn).to eq("978-3-16-1484100")
      end

      it "upcases the string" do
        file = create(:pdf_product_file, isbn: "097522980x")
        expect(file.isbn).to eq("097522980X")
      end

      it "strips whitespace from the string" do
        file = create(:pdf_product_file, isbn: "  097522980X  ")
        expect(file.isbn).to eq("097522980X")
      end

      it "nullifies isbn if blank or only whitespace" do
        file = create(:pdf_product_file, isbn: "   ")
        expect(file.isbn).to be_nil
      end
    end

    context "validation" do
      context "when pdf" do
        it "is valid with a valid isbn-13" do
          product_file = build(:pdf_product_file, isbn: Faker::Code.isbn(base: 13))
          expect(product_file).to be_valid
        end

        it "is valid with a valid isbn-10" do
          product_file = build(:pdf_product_file, isbn: Faker::Code.isbn)
          expect(product_file).to be_valid
        end

        it "is invalid with an invalid isbn" do
          product_file = build(:pdf_product_file, isbn: "invalid-isbn")
          expect(product_file).to be_invalid
          expect(product_file.errors.full_messages).to include(a_string_including("is not a valid ISBN-10 or ISBN-13"))
        end

        it "is valid with a nil isbn" do
          product_file = build(:pdf_product_file, isbn: nil)
          expect(product_file).to be_valid
        end
      end

      context "when epub" do
        it "is valid with a valid isbn-13" do
          product_file = build(:epub_product_file, isbn: Faker::Code.isbn(base: 13))
          expect(product_file).to be_valid
        end

        it "is valid with a valid isbn-10" do
          product_file = build(:epub_product_file, isbn: Faker::Code.isbn)
          expect(product_file).to be_valid
        end

        it "is invalid with an invalid isbn" do
          product_file = build(:epub_product_file, isbn: "invalid-isbn")
          expect(product_file).to be_invalid
          expect(product_file.errors.full_messages).to include(a_string_including("is not a valid ISBN-10 or ISBN-13"))
        end

        it "is valid with a nil isbn" do
          product_file = build(:epub_product_file, isbn: nil)
          expect(product_file).to be_valid
        end
      end

      context "when unrelated file type" do
        it "doesn't allow isbn" do
          product_file = build(:streamable_video, isbn: "invalid-isbn")
          expect(product_file).to be_invalid
          expect(product_file.errors.full_messages).to include("Isbn must be blank")
        end
      end
    end
  end

  describe "scopes" do
    describe ".in_order" do
      it "returns files in ascending order of positions" do
        product_file_1 = create(:streamable_video, position: 3)
        product_file_2 = create(:readable_document, position: 2)
        product_file_3 = create(:listenable_audio, position: 1)

        expect(ProductFile.in_order).to eq([product_file_3, product_file_2, product_file_1])
      end
    end

    describe ".ordered_by_ids" do
      it "returns files in order of ids" do
        product_file_1 = create(:streamable_video)
        product_file_2 = create(:readable_document)
        product_file_3 = create(:listenable_audio)
        product_file_4 = create(:product_file)

        expect(ProductFile.ordered_by_ids([product_file_3.id, product_file_1.id, product_file_4.id, product_file_2.id])).to eq([product_file_3, product_file_1, product_file_4, product_file_2])
      end
    end

    describe ".pdf" do
      it "filters out non-pdf files" do
        create(:external_link)
        create(:listenable_audio)
        create(:streamable_video)
        create(:non_readable_document)
        pdf_file = create(:readable_document)

        product_files = ProductFile.pdf

        expect(product_files.count).to eq(1)
        expect(product_files).to include(pdf_file)
      end
    end

    describe ".not_external_link" do
      it "filters out external link files" do
        create(:product_file, filetype: "link", url: "https://www.gumroad.com")
        create(:product_file, filetype: "link", url: "https://www.twitter.com")
        not_external_link_file_1 = create(:streamable_video)
        not_external_link_file_2 = create(:readable_document)

        product_files = ProductFile.not_external_link
        expect(product_files.count).to eq(2)
        expect(product_files).to include(not_external_link_file_1)
        expect(product_files).to include(not_external_link_file_2)
      end
    end
  end

  describe "#cannot_be_stamped?" do
    let(:product_file) { create(:pdf_product_file) }

    context "when stampable_pdf is nil" do
      it "returns false" do
        expect(product_file.cannot_be_stamped?).to be(false)
      end
    end

    context "when stampable_pdf is false" do
      before { product_file.update!(stampable_pdf: false) }

      it "returns true" do
        expect(product_file.cannot_be_stamped?).to be(true)
      end
    end

    context "when stampable_pdf is true" do
      before { product_file.update!(stampable_pdf: true) }

      it "returns false" do
        expect(product_file.cannot_be_stamped?).to be(false)
      end
    end
  end

  describe "callbacks" do
    describe "#stamp_existing_pdfs_if_needed" do
      let(:file) { create(:pdf_product_file) }
      let(:purchase) { create(:purchase, seller: file.user, link: file.link) }

      before { purchase.create_artifacts_and_send_receipt! }

      context "when PDF stamping is newly enabled" do
        it "enqueues a job to stamp existing PDFs if needed" do
          file.update!(pdf_stamp_enabled: true)
          expect(BackfillPdfStampsJob).to have_enqueued_sidekiq_job(file.link.id)
        end
      end

      context "when the same save makes the file a PDF" do
        it "checks it can be stamped once and starts one backfill" do
          key = "attachments/#{SecureRandom.hex}/original/notes.pdf"
          Aws::S3::Resource.new.bucket(S3_BUCKET).object(key).put(body: File.binread(Rails.root.join("spec/support/fixtures/billion-dollar-company-chapter-0.pdf")))
          text_file = create(:product_file, url: "#{S3_BASE_URL}attachments/#{SecureRandom.hex}/original/notes.txt")

          text_file.link.save_files!([{ external_id: text_file.external_id, url: "#{S3_BASE_URL}#{key}", pdf_stamp_enabled: true }])

          expect(PdfUnstampableNotifierJob.jobs.size).to eq(1)
          PdfUnstampableNotifierJob.drain
          expect(text_file.reload.stampable_pdf).to be(true)
          expect(BackfillPdfStampsJob.jobs.map { _1["args"] }).to eq([[text_file.link_id]])
        end
      end

      context "when PDF stamping is newly disabled" do
        let(:file) { create(:pdf_product_file, pdf_stamp_enabled: true) }

        it "does not enqueue a job to stamp existing PDFs" do
          file.update!(pdf_stamp_enabled: false)
          expect(BackfillPdfStampsJob).not_to have_enqueued_sidekiq_job(file.link.id)
        end
      end
    end
  end

  describe "#signed_url" do
    let(:product_file) { create(:product_file) }

    it "returns nil when the S3 object does not exist" do
      allow_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename)
        .and_raise(Aws::S3::Errors::NotFound.new(nil, "Not Found"))

      expect(product_file.signed_url).to be_nil
    end

    it "returns the url for external links" do
      product_file.update!(filetype: "link", url: "https://example.com/file.zip")
      expect(product_file.signed_url).to eq("https://example.com/file.zip")
    end
  end

  describe "#as_json video dimensions" do
    # The product editor shapes its video preview from these, so a portrait
    # video the seller filmed on a phone is not pillarboxed into a landscape
    # box in their own editor. See gumroad-private#1392.
    it "includes the recorded dimensions for a video file" do
      video = create(:streamable_video, width: 1080, height: 1920)

      expect(video.as_json).to include(width: 1080, height: 1920)
    end

    it "reports nil dimensions for a non-video file" do
      expect(create(:readable_document).as_json).to include(width: nil, height: nil)
    end

    it "reports nil dimensions for a video that was never measured" do
      video = create(:streamable_video, width: nil, height: nil)

      expect(video.as_json).to include(width: nil, height: nil)
    end
  end

  describe "subtitle file S3 NotFound handling" do
    let(:product_file) { create(:product_file) }
    let(:english_srt_url) { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/english.srt" }
    let(:missing_srt_url) { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/missing.srt" }
    let(:subtitle_file_en) { create(:subtitle_file, language: "English", url: english_srt_url, product_file:) }
    let(:subtitle_file_missing) { create(:subtitle_file, language: "Missing", url: missing_srt_url, product_file:) }

    before do
      allow_any_instance_of(SignedUrlHelper).to(
        receive(:signed_download_url_for_s3_key_and_filename)
          .with(subtitle_file_en.s3_key, subtitle_file_en.s3_filename, is_video: true).and_return(english_srt_url))
      allow_any_instance_of(SignedUrlHelper).to(
        receive(:signed_download_url_for_s3_key_and_filename)
          .with(subtitle_file_missing.s3_key, subtitle_file_missing.s3_filename, is_video: true)
          .and_raise(Aws::S3::Errors::NotFound.new(nil, "Not Found")))
    end

    describe "#as_json" do
      it "excludes subtitle files whose S3 object does not exist" do
        json = product_file.as_json
        subtitle_languages = json[:subtitle_files].map { |sf| sf[:language] }
        expect(subtitle_languages).to eq(["English"])
      end
    end

    describe "#subtitle_files_for_mobile" do
      it "excludes subtitle files whose S3 object does not exist" do
        result = product_file.subtitle_files_for_mobile
        expect(result).to eq([{ url: english_srt_url, language: "English" }])
      end
    end
  end
end
