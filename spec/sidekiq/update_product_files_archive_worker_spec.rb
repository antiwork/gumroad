# frozen_string_literal: true

require "spec_helper"

describe UpdateProductFilesArchiveWorker, :vcr do
  describe "#perform" do
    before do
      @long_file_name = "2d04543f25c2abbea7740c6abf71d07a12abff9b6ef45f1fabab0b6efb4679643f87131f869bbc7a2a146c3730ee57c65839"

      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    end

    context "when rich content provider is not present" do
      before do
        installment = create(:installment)
        installment.product_files << create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3")
        installment.product_files << create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3")
        installment.product_files << create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/#{@long_file_name}.csv")
        installment.product_files << create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/#{@long_file_name}.csv")
        installment.product_files << create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/#{@long_file_name}.csv")
        installment.product_files << create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/#{@long_file_name}.csv")
        installment.product_files << create(:streamable_video)
        installment.product_files << create(:streamable_video, stream_only: true)
        installment.product_files << create(:product_file, url: "https://www.gumroad.com", filetype: "link")

        @product_files_archive = installment.product_files_archives.create!
        @product_files_archive.product_files = installment.product_files
        @product_files_archive.save!
        @product_files_archive.set_url_if_not_present
        @product_files_archive.save!
      end

      it "creates a zip archive of product files while skipping external link and stream only files" do
        expect(@product_files_archive.queueing?).to be(true)
        UpdateProductFilesArchiveWorker.new.perform(@product_files_archive.id)
        @product_files_archive.reload
        expect(@product_files_archive.ready?).to be(true)
        expect(@product_files_archive.url).to match(/gumroad-specs\/attachments_zipped/)
        expect(@product_files_archive.url).to end_with("zip")

        temp_file = Tempfile.new
        @product_files_archive.s3_object.download_file(temp_file.path)
        temp_file.rewind

        entries = []
        Zip::File.open(temp_file.path) do |zipfile|
          zipfile.each do |entry|
            entries << entry.name.force_encoding("UTF-8")
          end
        end

        temp_file.close!

        expect(entries.count).to eq(7)
        expect(entries).to include("magic.mp3")

        # Makes sure all file names in the generated zip are unique
        expect(entries).to include("magic-1.mp3")

        # Truncates long file names
        truncated_long_filename = @long_file_name.truncate_bytes(described_class::MAX_FILENAME_BYTESIZE, omission: nil)
        expect(entries).to include("#{truncated_long_filename}.csv")

        # Makes sure all file names are unique, even when filename is truncated
        expect(entries).to include("#{truncated_long_filename}-1.csv")

        expect(@product_files_archive.s3_object.content_type).to eq("application/zip")
      end

      context "when product files archive is marked as deleted" do
        before do
          @product_files_archive.mark_deleted!
        end

        it "doesn't update the archive" do
          expect do
            expect(described_class.new.perform(@product_files_archive.id)).to be_nil
          end.not_to change { @product_files_archive.reload.product_files_archive_state }
        end
      end
    end

    context "when rich content provider is present" do
      before do
        @product = create(:product)
        @product_file1 = create(:readable_document, display_name: "जीवन में यश एवम् समृद्धी प्राप्त करने के कहीं न बताये जाने वाले १०० उपाय")
        @product_file2 = create(:readable_document, display_name: "कैसे जीवन का आनंद ले")
        @product_file3 = create(:readable_document, display_name: "File 3")
        @product_file4 = create(:readable_document, display_name: "आनंद और सुखी जीवन के लिए जाने कुछ रहस्य जो आपको नहीं पता होंगे और जिन्हें आपको जानना चाहिए")
        @product_file5 = create(:readable_document, display_name: "File 5")
        @product.product_files = [@product_file1, @product_file2, @product_file3, @product_file4, @product_file5]
        @product.save!
        @page1 = create(:rich_content, entity: @product, description: [
                          { "type" => "fileEmbed", "attrs" => { "id" => @product_file1.external_id, "uid" => "file-1" } },
                        ])
        @page2 = create(:rich_content, entity: @product, title: "Page 2", description: [
                          { "type" => "fileEmbedGroup", "attrs" => { "name" => "" }, "content" => [
                            { "type" => "fileEmbed", "attrs" => { "id" => @product_file2.external_id, "uid" => "0c042930-2df1-4583-82ef-a63172138683" } },
                          ] },
                          { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Some text" }] },
                          { "type" => "fileEmbedGroup", "attrs" => { "name" => "" }, "content" => [
                            { "type" => "fileEmbed", "attrs" => { "id" => @product_file3.external_id, "uid" => "0c042930-2df1-4583-82ef-a6317213868f" } },
                          ] },
                        ])
        @folder_id = SecureRandom.uuid
        @page3 = create(:rich_content, entity: @product, description: [
                          { "type" => "fileEmbedGroup", "attrs" => { "name" => "आनंदमय जीवन जिने के ५ सरल उपाय", "uid": @folder_id }, "content" => [
                            { "type" => "fileEmbed", "attrs" => { "id" => @product_file4.external_id, "uid" => "0c042930-2df1-4583-82ef-a6317213868w" } },
                            { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Lorem ipsum" }] },
                            { "type" => "fileEmbed", "attrs" => { "id" => @product_file5.external_id, "uid" => "0c042930-2df1-4583-82ef-a63172138681" } },
                          ] },
                        ])
        @product_files_archive = @product.product_files_archives.create!
        @product_files_archive.product_files = @product.product_files
        @product_files_archive.save!
        @product_files_archive.set_url_if_not_present
        @product_files_archive.save!

        @folder_archive = @product.product_files_archives.create!(folder_id: @folder_id)
        @folder_archive.product_files = [@product_file4, @product_file5]
        @folder_archive.save!
        @folder_archive.set_url_if_not_present
        @folder_archive.save!
      end

      it "creates a zip archive of embedded ungrouped files and grouped files while skipping external link and stream only files" do
        UpdateProductFilesArchiveWorker.new.perform(@product_files_archive.id)
        @product_files_archive.reload
        expect(@product_files_archive.url).to end_with("zip")

        temp_file = Tempfile.new
        @product_files_archive.s3_object.download_file(temp_file.path)
        temp_file.rewind

        entries = []
        Zip::File.open(temp_file.path) do |zipfile|
          zipfile.each do |entry|
            entries << entry.name.force_encoding("UTF-8")
          end
        end

        temp_file.close!

        expect(entries.count).to eq(5)
        expect(entries).to match_array([
                                         # Truncates long file name "जीवन में यश एवम् समृद्धी प्राप्त करने के कहीं न बताये जाने वाले १०० उपाय" enclosed in a folder named "Page 1" (title of the page)
                                         "Untitled 1/जीवन में यश एवम् समृद्धी प्राप्त करने .pdf",

                                         # Enclose the file in nested folders, "Page 2" (title of the page) and "Untitled 2" (name of the file group)
                                         "Page 2/Untitled 1/कैसे जीवन का आनंद ले.pdf",

                                         # Enclose the file in a folder named "Page 2" (title of the page)
                                         "Page 2/Untitled 2/File 3.pdf",

                                         # Truncates long file name "आनंद और सुखी जीवन के लिए जाने कुछ रहस्य जो आपको नहीं पता होंगे और जिन्हें आपको जानना चाहिए" enclosed in nested folders, "Untitled 2" (fallback title of the page) and "आनंदमय जीवन जिने के ५ सरल उपाय" (name of the file group, which gets truncated as well)
                                         "Untitled 2/आनंदमय जीवन जिने के ५ स/आनंद और सुखी जीवन के लिए जा.pdf",

                                         # Enclose the file in nested folders, "Untitled 2" (fallback title of the page) and "आनंदमय जीवन जिने के ५ सरल उपाय" (name of the file group)
                                         "Untitled 2/आनंदमय जीवन जिने के ५ सरल उपाय/File 5.pdf"
                                       ])
      end

      it "creates a zip archive of folder files" do
        UpdateProductFilesArchiveWorker.new.perform(@folder_archive.id)
        @folder_archive.reload
        expect(@folder_archive.url).to end_with("zip")
        expect(@folder_archive.url).to include("आनंदमय_जीवन_जिने_के_५_सरल_उपाय")

        temp_file = Tempfile.new
        @folder_archive.s3_object.download_file(temp_file.path)
        temp_file.rewind

        entries = []
        Zip::File.open(temp_file.path) do |zipfile|
          zipfile.each do |entry|
            entries << entry.name.force_encoding("UTF-8")
          end
        end

        temp_file.close!

        expect(entries.count).to eq(2)
        expect(entries).to match_array(
          [
            "आनंद और सुखी जीवन के लिए जाने कुछ रहस्य जो आपको नहीं पता .pdf",
            "File 5.pdf"
          ])
      end
    end
  end
end
