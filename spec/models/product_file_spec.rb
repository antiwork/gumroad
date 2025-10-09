# frozen_string_literal: true

require "spec_helper"

describe ProductFile do
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
    let!(:file_1) { create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/some-file.pdf") }
    let!(:file_2) { create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/some-file.pdf") }

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
        create(:readable_document, stream_only: true),
        create(:non_readable_document),
        create(:listenable_audio)
      ]
      non_archivable = [
        create(:streamable_video, stream_only: true),
        create(:product_file, filetype: "link", url: "http://gumroad.com")
      ]

      expect(archivable.all?(&:archivable?)).to eq(true)
      expect(non_archivable.any?(&:archivable?)).to eq(false)
    end
  end

  describe "#stream_only?" do
    it "returns false for non-video file" do
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

    it "returns false for non-video file marked as stream_only" do
      product_file = create(:readable_document, stream_only: true)

      expect(product_file.stream_only?).to eq(false)
    end

    it "returns true for streamable video file marked as stream_only" do
      product_file = create(:streamable_video, stream_only: true)

      expect(product_file.stream_only?).to eq(true)
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
      product_file = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/specs/test file %26 & ) %29.txt")
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
        new_name = "A" * 800
        expect(MultipartTransfer).to receive(:transfer_to_s3).with(/billion-dollar-company-chapter-0.pd/,
                                                                   destination_filename: "#{new_name}.pdf",
                                                                   existing_s3_object: instance_of(@product_file.s3_object.class)).and_call_original

        @product_file.update!(display_name: new_name)
        @product_file.reload

        expect(@product_file.url).to match %r(attachments/[a-f\d]{32}/original/#{new_name}.pdf)
        expect(@product_file.name_displayable).to eq(new_name)
      end
    end

    it "creates the product file with filetype set to lowercase" do
      product_file = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/fc34ee33bae54181badd048c71209d24/original/sample.PDF")
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
      @product_file = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/files/43a5363194e74e9ee75b6203eaea6705/original/black/white.mp4")
    end

    it "handles / in the filename properly" do
      expect(@product_file.s3_key).to eq("files/43a5363194e74e9ee75b6203eaea6705/original/black/white.mp4")
      expect(@product_file.s3_filename).to eq("black/white.mp4")
      expect(@product_file.s3_display_name).to eq("black/white")
      expect(@product_file.s3_extension).to eq(".mp4")
      expect(@product_file.s3_display_extension).to eq("MP4")
    end

    it "works as expected for files without an extension" do
      @product_file.update!(url: "https://s3.amazonaws.com/gumroad-specs/files/43a5363194e74e9ee75b6203eaea6705/original/black/white")

      expect(@product_file.s3_key).to eq("files/43a5363194e74e9ee75b6203eaea6705/original/black/white")
      expect(@product_file.s3_filename).to eq("black/white")
      expect(@product_file.s3_display_name).to eq("black/white")
      expect(@product_file.s3_extension).to eq("")
      expect(@product_file.s3_display_extension).to eq("")
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
      @file_1 = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter 2.mp4", is_transcoded_for_hls: true)
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
        url += "Signature=vanawCHC4r2A+uhez+lPVIjGTN+wYkgEoEwQ4QROsfcW7L4CPGCraydEonwriLbfyCKwstKYgZU4EXIefbFtboqq/34TcJsrbuabd890HeHJ7whSg/I7RoWoHJJ9J48N9wFZ4LyqY9PlWM8vhI3WBr7TV1THyuB1F/fieQ+Sr5o=&"
        url += "Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n"
        url += "#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=1280x720,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=2805000\n"
        url += "https://d1jmbc8d0c0hid.cloudfront.net/attachments/2_1/original/chapter+2/hls/hls_720p_.m3u8?Expires=1426248000&"
        url += "Signature=n4AQRij+ip3QPK9PLbc3pElA3/YytwV83I33fppz/va+8ecgU04keHvLkL7olIWu3mNQjX/xYGmnvJJucPKBuqKNpATMdUBo2yr70gsEo3FW7tmrHjZQWBFObvMkNR0FFb3syow5X71JQRCkmkaer3y6x7EMyKUxwcH8lCxx2+4=&"
        url += "Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n"
        expect(hls_playlist).to eq url
      end
    end

    it "escapes the user-provided filename even if the user has changed the filename since the video was transcoded" do
      @file_1.update!(url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter_2_no_spaces.mp4")
      travel_to(Date.parse("2015-03-13")) do
        hls_playlist = @file_1.hls_playlist
        url = "#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=854x480,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=1191000\n"
        url += "https://d1jmbc8d0c0hid.cloudfront.net/attachments/2_1/original/chapter+2/hls/hls_480p_.m3u8?Expires=1426248000&" # Notice the + in chapter+2
        url += "Signature=vanawCHC4r2A+uhez+lPVIjGTN+wYkgEoEwQ4QROsfcW7L4CPGCraydEonwriLbfyCKwstKYgZU4EXIefbFtboqq/34TcJsrbuabd890HeHJ7whSg/I7RoWoHJJ9J48N9wFZ4LyqY9PlWM8vhI3WBr7TV1THyuB1F/fieQ+Sr5o=&"
        url += "Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n"
        url += "#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=1280x720,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=2805000\n"
        url += "https://d1jmbc8d0c0hid.cloudfront.net/attachments/2_1/original/chapter+2/hls/hls_720p_.m3u8?Expires=1426248000&" # Notice the + in chapter+2
        url += "Signature=n4AQRij+ip3QPK9PLbc3pElA3/YytwV83I33fppz/va+8ecgU04keHvLkL7olIWu3mNQjX/xYGmnvJJucPKBuqKNpATMdUBo2yr70gsEo3FW7tmrHjZQWBFObvMkNR0FFb3syow5X71JQRCkmkaer3y6x7EMyKUxwcH8lCxx2+4=&"
        url += "Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n"
        expect(hls_playlist).to eq url
      end
    end

    it "escapes the filename in legacy S3 attachments" do
      file = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/0000134abcdefghhijkl354sfdg/chapter 2.mp4", is_transcoded_for_hls: true)
      @multifile_product.product_files << file
      @transcoded_video = create(:transcoded_video, link: @multifile_product, streamable: file, original_video_key: file.s3_key,
                                                    transcoded_video_key: "attachments/0000134abcdefghhijkl354sfdg/chapter 2/hls/index.m3u8",
                                                    is_hls: true, state: "completed")
      expect(file.hls_playlist).to include("attachments/0000134abcdefghhijkl354sfdg/chapter+2/hls/hls_480p_.m3u8")
    end

    it "escapes the newlines in the filename" do
      file = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/12345/abcd12345/original/YouTube + Marketing Is Powerful\n.mp4", is_transcoded_for_hls: true)
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
      let(:english_srt_url) { "https://s3.amazonaws.com/gumroad-specs/attachment/english.srt" }
      let(:french_srt_url) { "https://s3.amazonaws.com/gumroad-specs/attachment/french.srt" }
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
      @file = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter 2.mp4", is_transcoded_for_hls: true)
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

  describe "#display_extension" do
    it "returns URL for files which are external links" do
      product_file = create(:product_file, filetype: "link", url: "http://gumroad.com")
      expect(product_file.display_extension).to eq("URL")
    end

    it "returns extension for s3 files with an extension" do
      product_file = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/files/43a5363194e74e9ee75b6203eaea6705/original/black/white.mp4")
      expect(product_file.display_extension).to eq("MP4")
    end

    it "returns empty string for s3 files without an extension" do
      product_file = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/files/43a5363194e74e9ee75b6203eaea6705/original/black/white")
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
      installment_product_file = create(:product_file, installment:, link: installment.link)
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
        expect(product_file.thumbnail_variant.url).to match("https://gumroad-specs.s3.amazonaws.com/#{product_file.thumbnail_variant.key}")
      end
    end

    describe "#thumbnail_url" do
      it "returns nil if no thumbnail exists" do
        product_file = create(:readable_document)

        expect(product_file.thumbnail.attached?).to be(false)
        expect(product_file.thumbnail_url).to be_nil
      end

      it "returns the CDN URL if thumbnail exists" do
        stub_const("CDN_URL_MAP", { "https://gumroad-specs.s3.amazonaws.com" => "https://public-files.gumroad.com" })

        product_file = create(:streamable_video)
        product_file.thumbnail.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")), filename: "smilie.png")

        expect(product_file.thumbnail_url).to match("https://public-files.gumroad.com/#{product_file.thumbnail_variant.key}")
      end

      it "returns the original thumbnail URL when the thumbnail variant processing fails" do
        product_file = create(:streamable_video)
        product_file.thumbnail.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")), filename: "smilie.png")

        allow(product_file).to receive(:thumbnail_variant).and_raise(ActiveStorage::InvariableError)

        expect(product_file.thumbnail_url).to match("https://gumroad-specs.s3.amazonaws.com/#{product_file.thumbnail.key}")
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
        file = create(:pdf_product_file, isbn: "978316148410x")
        expect(file.isbn).to eq("978316148410X")
      end

      it "strips whitespace from the string" do
        file = create(:pdf_product_file, isbn: "  978316148410X  ")
        expect(file.isbn).to eq("978316148410X")
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
    describe "#reset_moderated_by_iffy_flag" do
      let(:product) { create(:product, moderated_by_iffy: true) }

      context "when an image product file is created" do
        it "resets moderated_by_iffy flag on the associated product" do
          expect do
            create(:product_file, link: product, url: "https://s3.amazonaws.com/gumroad-specs/specs/kFDzu.png")
          end.to change { product.reload.moderated_by_iffy }.from(true).to(false)
        end
      end

      context "when a non-image product file is created" do
        it "does not reset moderated_by_iffy flag on the associated product" do
          expect do
            create(:product_file, link: product)
          end.to_not change { product.reload.moderated_by_iffy }
        end
      end
    end

    describe "#stamp_existing_pdfs_if_needed" do
      let(:file) { create(:pdf_product_file) }
      let(:purchase) { create(:purchase, seller: file.user, link: file.link) }

      before { purchase.create_artifacts_and_send_receipt! }

      context "when PDF stamping is newly enabled" do
        it "enqueues a job to stamp existing PDFs if needed" do
          file.update!(pdf_stamp_enabled: true)
          expect(StampPdfForPurchaseJob).to have_enqueued_sidekiq_job(purchase.id)
        end
      end

      context "when PDF stamping is newly disabled" do
        let(:file) { create(:pdf_product_file, pdf_stamp_enabled: true) }

        it "does not enqueue a job to stamp existing PDFs" do
          file.update!(pdf_stamp_enabled: false)
          expect(StampPdfForPurchaseJob).not_to have_enqueued_sidekiq_job(purchase.id)
        end
      end
    end
  end
end
