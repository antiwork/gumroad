# frozen_string_literal: true

require "spec_helper"

describe WithProductFiles do
  describe "associations" do
    context "has many `product_folders`" do
      it "does not return deleted folders" do
        product = create(:product)
        folder_1 = create(:product_folder, link: product)
        create(:product_folder, link: product)
        expect do
          folder_1.mark_deleted!
        end.to change { product.product_folders.count }.by(-1)
      end
    end
  end

  describe "#needs_updated_entity_archive?" do
    it "returns false when irrelevant changes are made to a product's rich content" do
      product_file1 = create(:product_file, display_name: "First file")
      product = create(:product, product_files: [product_file1])

      page1 = create(:rich_content, entity: product, title: "Page 1", description: [
                       { "type" => "fileEmbed", "attrs" => { "id" => product_file1.external_id, "uid" => SecureRandom.uuid } },
                     ])

      archive = product.product_files_archives.create!(product_files: product.product_files)
      archive.mark_in_progress!
      archive.mark_ready!

      expect(product.needs_updated_entity_archive?).to eq(false)

      page1.description << { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Irrelevant change" }] }
      page1.save!

      expect(product.needs_updated_entity_archive?).to eq(false)
    end

    it "returns false when the product contains only stream-only files" do
      product = create(:product, product_files: [create(:streamable_video, stream_only: true), create(:streamable_video, stream_only: true)])

      expect(product.needs_updated_entity_archive?).to eq(false)
    end

    it "returns false when the product contains stampable PDFs" do
      product = create(:product, product_files: [create(:product_file), create(:readable_document, pdf_stamp_enabled: true)])

      expect(product.needs_updated_entity_archive?).to eq(false)
    end

    it "returns true when an entity archive has not been created yet" do
      product_file1 = create(:product_file, display_name: "First file")
      product = create(:product, product_files: [product_file1])

      create(:rich_content, entity: product, title: "Page 1", description: [
               { "type" => "fileEmbed", "attrs" => { "id" => product_file1.external_id, "uid" => SecureRandom.uuid } },
             ])

      expect(product.needs_updated_entity_archive?).to eq(true)
    end

    it "returns true when relevant changes have been made to an entity's rich content" do
      file1 = create(:product_file, display_name: "First file")
      file2 = create(:product_file, display_name: "Second file")
      product = create(:product, product_files: [file1, file2])

      description = [
        { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => SecureRandom.uuid }, "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
        ] }]
      page1 = create(:rich_content, entity: product, title: "Page 1", description:)

      expect(product.needs_updated_entity_archive?).to eq(true)

      archive = product.product_files_archives.create!(product_files: product.product_files)
      archive.mark_in_progress!
      archive.mark_ready!

      page1.description.first["attrs"]["name"] = "New folder name!"
      page1.save!

      expect(Link.find(product.id).needs_updated_entity_archive?).to eq(true)
    end
  end

  describe "#map_rich_content_files_and_folders" do
    context "when there is no rich content provider" do
      it "returns an empty hash" do
        entity = create(:installment)
        entity.product_files = [create(:product_file), create(:product_file)]

        expect(entity.map_rich_content_files_and_folders).to eq({})
      end
    end

    context "when the rich content has no files" do
      it "returns an empty hash" do
        product = create(:product)

        expect(product.map_rich_content_files_and_folders).to eq({})
      end
    end

    context "when the rich content has files" do
      context "when the rich content has only one untitled default page" do
        it "does not include the fallback page title in the mapping" do
          product_file1 = create(:product_file, display_name: "First file")
          product_file2 = create(:product_file, display_name: "Second file")
          product = create(:product)
          product.product_files = [product_file1, product_file2]
          product.save!
          page1 = create(:rich_content, entity: product, description: [
                           { "type" => "fileEmbed", "attrs" => { "id" => product_file1.external_id, "uid" => SecureRandom.uuid } },
                           { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "This is a paragraph" }] },
                           { "type" => "fileEmbed", "attrs" => { "id" => product_file2.external_id, "uid" => SecureRandom.uuid } }
                         ])

          expect(product.map_rich_content_files_and_folders).to eq(
            product_file1.id => { page_id: page1.external_id,
                                  page_title: page1.title.presence,
                                  folder_id: nil,
                                  folder_name: nil,
                                  file_id: product_file1.external_id,
                                  file_name: product_file1.name_displayable },
            product_file2.id => { page_id: page1.external_id,
                                  page_title: page1.title.presence,
                                  folder_id: nil,
                                  folder_name: nil,
                                  file_id: product_file2.external_id,
                                  file_name: product_file2.name_displayable }
          )
        end
      end

      context "when the rich content has multiple pages" do
        it "includes the custom page titles as well as the incremented untitled page titles in the mapping" do
          product_file1 = create(:product_file, display_name: "First file")
          product_file2 = create(:product_file, display_name: "Second file")
          product_file3 = create(:product_file, display_name: "Third file")
          product = create(:product)
          product.product_files = [product_file1, product_file2, product_file3]
          product.save!
          page1 = create(:rich_content, entity: product, description: [
                           { "type" => "fileEmbed", "attrs" => { "id" => product_file1.external_id, "uid" => SecureRandom.uuid } },
                         ])
          page2 = create(:rich_content, entity: product, title: "Page 2", description: [
                           { "type" => "fileEmbed", "attrs" => { "id" => product_file2.external_id, "uid" => SecureRandom.uuid } },
                         ])
          page3 = create(:rich_content, entity: product, description: [
                           { "type" => "fileEmbed", "attrs" => { "id" => product_file3.external_id, "uid" => SecureRandom.uuid } },
                         ])

          page1.title = "Untitled 1"
          page3.title = "Untitled 2"
          expect(product.map_rich_content_files_and_folders).to eq(
            product_file1.id => { page_id: page1.external_id,
                                  page_title: page1.title.presence,
                                  folder_id: nil,
                                  folder_name: nil,
                                  file_id: product_file1.external_id,
                                  file_name: product_file1.name_displayable },
            product_file2.id => { page_id: page2.external_id,
                                  page_title: page2.title.presence,
                                  folder_id: nil,
                                  folder_name: nil,
                                  file_id: product_file2.external_id,
                                  file_name: product_file2.name_displayable },
            product_file3.id => { page_id: page3.external_id,
                                  page_title: page3.title.presence,
                                  folder_id: nil,
                                  folder_name: nil,
                                  file_id: product_file3.external_id,
                                  file_name: product_file3.name_displayable }
          )
        end
      end

      context "when the rich content has file groups" do
        it "includes the custom folder names as well as the incremented untitled folder names in the mapping" do
          product_file1 = create(:product_file, display_name: "First file")
          product_file2 = create(:product_file, display_name: "Second file")
          product_file3 = create(:product_file, display_name: "Third file")
          product_file4 = create(:product_file, display_name: "Fourth file")
          product_file5 = create(:product_file, display_name: "Fifth file")
          product = create(:product)
          product.product_files = [product_file1, product_file2, product_file3, product_file4, product_file5]
          product.save!
          page2_folder1 = { "name" => "", "uid" => SecureRandom.uuid }
          page2_folder2 = { "name" => "", "uid" => SecureRandom.uuid }
          page3_folder1 = { "name" => "Folder 3", "uid" => SecureRandom.uuid }
          page1 = create(:rich_content, entity: product, title: "Page 1", description: [
                           { "type" => "fileEmbed", "attrs" => { "id" => product_file1.external_id, "uid" => SecureRandom.uuid } },
                         ])
          page2 = create(:rich_content, entity: product, title: "Page 2", description: [
                           { "type" => "fileEmbedGroup", "attrs" => page2_folder1, "content" => [
                             { "type" => "fileEmbed", "attrs" => { "id" => product_file2.external_id, "uid" => SecureRandom.uuid } },
                           ] },
                           { "type" => "fileEmbedGroup", "attrs" => page2_folder2, "content" => [
                             { "type" => "fileEmbed", "attrs" => { "id" => product_file3.external_id, "uid" => SecureRandom.uuid } },
                           ] },
                         ])
          page3 = create(:rich_content, entity: product, title: "Page 3", description: [
                           { "type" => "fileEmbedGroup", "attrs" => page3_folder1, "content" => [
                             { "type" => "fileEmbed", "attrs" => { "id" => product_file4.external_id, "uid" => SecureRandom.uuid } },
                             { "type" => "fileEmbed", "attrs" => { "id" => product_file5.external_id, "uid" => SecureRandom.uuid } },
                           ] },
                         ])
          product_files_archive = product.product_files_archives.create
          product_files_archive.product_files = product.product_files
          product_files_archive.mark_in_progress!
          product_files_archive.mark_ready!

          expect(product.map_rich_content_files_and_folders).to eq(
            product_file1.id => { page_id: page1.external_id,
                                  page_title: page1.title.presence,
                                  folder_id: nil,
                                  folder_name: nil,
                                  file_id: product_file1.external_id,
                                  file_name: product_file1.name_displayable },
            product_file2.id => { page_id: page2.external_id,
                                  page_title: page2.title.presence,
                                  folder_id: page2_folder1["uid"],
                                  folder_name: "Untitled 1",
                                  file_id: product_file2.external_id,
                                  file_name: product_file2.name_displayable },
            product_file3.id => { page_id: page2.external_id,
                                  page_title: page2.title.presence,
                                  folder_id: page2_folder2["uid"],
                                  folder_name: "Untitled 2",
                                  file_id: product_file3.external_id,
                                  file_name: product_file3.name_displayable },
            product_file4.id => { page_id: page3.external_id,
                                  page_title: page3.title.presence,
                                  folder_id: page3_folder1["uid"],
                                  folder_name: page3_folder1["name"],
                                  file_id: product_file4.external_id,
                                  file_name: product_file4.name_displayable },
            product_file5.id => { page_id: page3.external_id,
                                  page_title: page3.title.presence,
                                  folder_id: page3_folder1["uid"],
                                  folder_name: page3_folder1["name"],
                                  file_id: product_file5.external_id,
                                  file_name: product_file5.name_displayable  }
          )
        end
      end
    end
  end

  describe "#has_stream_only_files?" do
    let(:product) { create(:product) }

    it "returns false if product has no files" do
      expect(product.has_stream_only_files?).to eq(false)
    end

    it "returns false if product only has non-streamable files" do
      product.product_files << create(:readable_document)
      product.product_files << create(:non_streamable_video)

      expect(product.has_stream_only_files?).to eq(false)
    end

    it "returns false if product has streamable files that are not marked as stream-only" do
      product.product_files << create(:streamable_video)

      expect(product.has_stream_only_files?).to eq(false)
    end

    it "returns true if product has streamable files that are marked as stream-only" do
      product.product_files << create(:readable_document)
      product.product_files << create(:streamable_video)
      product.product_files << create(:streamable_video, stream_only: true)

      expect(product.has_stream_only_files?).to eq(true)
    end
  end

  describe "#stream_only?" do
    let(:product) { create(:product) }

    it "returns false if product has a file that is not stream-only" do
      product.product_files << create(:streamable_video, stream_only: true)
      product.product_files << create(:readable_document)

      expect(product.stream_only?).to eq(false)
    end

    it "returns true if product only has stream-only files" do
      product.product_files << create(:streamable_video, stream_only: true)
      product.product_files << create(:streamable_video, stream_only: true)

      expect(product.stream_only?).to eq(true)
    end
  end

  describe "#save_files!" do
    context "when called on a Link record" do
      let(:product) { create(:product_with_pdf_files_with_size) }

      it "enqueues a `PdfUnstampableNotifierJob` job when new stampable files are added" do
        product_files_params = product.product_files.each_with_object([]) { |file, params| params << { external_id: file.external_id, url: file.url } }
        product_files_params << { external_id: SecureRandom.uuid, pdf_stamp_enabled: false, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/nyt.pdf" }
        product_files_params << { external_id: SecureRandom.uuid, pdf_stamp_enabled: true, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf" }

        expect do
          product.save_files!(product_files_params)
        end.to change { product.product_files.alive.count }.by(2)

        expect(PdfUnstampableNotifierJob).to have_enqueued_sidekiq_job(product.id)
      end

      it "does not enqueue a `PdfUnstampableNotifierJob` job when new non-stampable files are added" do
        product_files_params = product.product_files.each_with_object([]) { |file, params| params << { external_id: file.external_id, url: file.url } }
        product_files_params << { external_id: SecureRandom.uuid, pdf_stamp_enabled: false, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf" }

        expect do
          product.save_files!(product_files_params)
        end.to change { product.product_files.alive.count }.by(1)

        expect(PdfUnstampableNotifierJob.jobs.size).to eq(0)
      end

      it "enqueues a `PdfUnstampableNotifierJob` job when existing files are marked as stampable" do
        expect(product.product_files.pdf.any?).to eq(true)

        product_files_params = product.product_files.each_with_object([]) { |file, params| params << { external_id: file.external_id, url: file.url, pdf_stamp_enabled: file.pdf? } }
        expect do
          product.save_files!(product_files_params)
        end.not_to change { product.product_files.alive.count }

        expect(PdfUnstampableNotifierJob).to have_enqueued_sidekiq_job(product.id)
      end

      it "does not enqueue a `PdfUnstampableNotifierJob` job when existing files are marked as non-stampable" do
        expect(product.product_files.pdf.present?).to eq(true)

        product.product_files.pdf.each { |file| file.update!(pdf_stamp_enabled: true) }

        product_files_params = product.product_files.each_with_object([]) { |file, params| params << { external_id: file.external_id, url: file.url, pdf_stamp_enabled: false } }
        expect do
          product.save_files!(product_files_params)
        end.not_to change { product.product_files.alive.count }

        expect(PdfUnstampableNotifierJob.jobs.size).to eq(0)
      end

      it "does not enqueue a `PdfUnstampableNotifierJob` job when existing files are removed" do
        expect do
          product.save_files!([])
        end.to change { product.product_files.alive.count }.by(-3)

        expect(PdfUnstampableNotifierJob.jobs.size).to eq(0)
      end

      it "does not enqueue a `PdfUnstampableNotifierJob` job when no changes are made to files" do
        product_files_params = product.product_files.each_with_object([]) { |file, acc| acc << { external_id: file.external_id, url: file.url } }

        expect do
          product.save_files!(product_files_params)
        end.not_to change { product.product_files.alive.count }

        expect(PdfUnstampableNotifierJob.jobs.size).to eq(0)
      end

      it "does not enqueue a `PdfUnstampableNotifierJob` job for a non-product resource" do
        post = create(:installment)

        expect do
          post.save_files!([{ external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf" }])
        end.to change { post.product_files.alive.count }.by(1)

        expect(PdfUnstampableNotifierJob.jobs.size).to eq(0)
      end

      it "sets content_updated_at when new files are added" do
        product_files_params = product.product_files.each_with_object([]) { |file, acc| acc << { external_id: file.external_id, url: file.url } }
        product_files_params << { external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pic.jpg" }
        product_files_params << { external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4" }

        freeze_time do
          expect do
            product.save_files!(product_files_params)
          end.to change { product.product_files.alive.count }.by(2)

          expect(product.content_updated_at_changed?).to eq true
          expect(product.content_updated_at).to eq Time.current
        end
      end

      it "does not set content_updated_at when existing files are removed" do
        expect do
          product.save_files!([{ external_id: product.product_files.first.external_id, url: product.product_files.first.url }])
        end.to change { product.product_files.alive.count }.by(-2)

        expect(product.content_updated_at_changed?).to eq false
      end

      it "updates file attributes" do
        product_files_params = product.product_files.each_with_object([]) { |file, acc| acc << { external_id: file.external_id, url: file.url } }

        product_files_params[0].merge!({ position: 2, display_name: "new book name", description: "new_description" })
        product_files_params << { external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pic.jpg", size: 2, position: 0 }
        product_files_params << { external_id: SecureRandom.uuid, url: "http://www.gum.road", size: "", filetype: "link", position: 1, display_name: "link file" }

        expect do
          product.save_files!(product_files_params)
        end.to change { product.product_files.alive.count }.by(2)

        book_file = product.product_files[0].reload
        expect(book_file.display_name).to eq("new book name")
        expect(book_file.description).to eq("new_description")
        expect(book_file.position).to eq(2)

        pic_file = product.product_files[3].reload
        expect(pic_file.position).to eq(0)

        link_file = product.product_files[4].reload
        expect(link_file.filetype).to eq("link")
        expect(link_file.display_name).to eq("link file")
        expect(link_file.position).to eq(1)
      end

      it "raises error on the product if url is invalid when creating an external link file" do
        product_files_params = product.product_files.each_with_object([]) { |file, acc| acc << { external_id: file.external_id, url: file.url } }
        product_files_params << { external_id: SecureRandom.uuid, url: "gum.road", size: "", filetype: "link" }

        expect do
          product.save_files!(product_files_params)
        end.to change { product.product_files.alive.count }.by(0)
           .and raise_error(ActiveRecord::RecordInvalid)

        expect(product.errors.full_messages).to include("gum.road is not a valid URL.")
      end

      it "preserves folder_id on file if folder is deleted" do
        product = create(:product)
        folder_1 = create(:product_folder, link: product, name: "Test Folder 1")
        folder_2 = create(:product_folder, link: product, name: "Test Folder 2")

        file_1 = create(:product_file, link: product, description: "pencil", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png", folder_id: folder_1.id)
        file_2 = create(:product_file, link: product, description: "manual", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf", folder_id: folder_2.id)

        product_files_params = product.product_files.each_with_object([]) { |file, acc| acc << { external_id: file.external_id, url: file.url, folder_id: file.folder_id } }

        folder_2.mark_deleted!

        product_files_params[1].merge!({ folder_id: nil })
        product.save_files!(product_files_params)

        expect(product.product_folders.reload.count).to eq(1)
        expect(folder_2.reload.deleted?).to eq(true)
        expect(file_1.reload.folder_id).to eq(folder_1.id)
        expect(file_2.reload.folder_id).to eq(folder_2.id)
      end

      it "preserves folder_id on file if folder does not exist" do
        product = create(:product)
        file = create(:readable_document, link: product, folder_id: 1000)
        product.save_files!([{ external_id: file.external_id, url: file.url, folder_id: nil }])
        expect(file.reload.folder_id).to eq(1000)
      end

      it "sets folder_id to nil if file is moved out of folder" do
        product = create(:product)
        folder = create(:product_folder, link: product)
        file_1 = create(:readable_document, folder:, link: product)
        file_2 = create(:streamable_video, folder:, link: product)
        file_3 = create(:listenable_audio, link: product)

        product_files_params = product.product_files.each_with_object([]) { |file, acc| acc << { external_id: file.external_id, url: file.url, folder_id: file.folder_id } }

        product_files_params[1].merge!({ folder_id: nil })
        product.save_files!(product_files_params)

        expect(file_1.reload.folder_id).to eq(folder.id)
        expect(file_2.reload.folder_id).to eq(nil)
        expect(file_3.reload.folder_id).to eq(nil)
      end

      it "respects the `modified` flag if present on file" do
        product = create(:product)
        file_1 = create(:readable_document, display_name: "name 1", link: product)
        file_2 = create(:streamable_video, display_name: "name 2", link: product)
        file_3 = create(:listenable_audio, display_name: "name 3", link: product)

        product_files_params = [
          {
            external_id: file_1.external_id,
            display_name: "new name 1",
            url: file_1.url,
            modified: "false"
          },
          {
            external_id: file_2.external_id,
            display_name: "new name 2",
            url: file_2.url,
            modified: "true"
          },
          {
            # Files without a `modified` flag are treated as `modified: true`
            external_id: file_3.external_id,
            display_name: "new name 3",
            url: file_2.url,
          }
        ]

        product.save_files!(product_files_params)

        expect(file_1.reload.display_name).to eq "name 1"
        expect(file_2.reload.display_name).to eq "new name 2"
        expect(file_3.reload.display_name).to eq "new name 3"
      end
    end

    context "when called on an Installment record" do
      let(:installment) { create(:installment) }

      it "does not enqueue a `PdfUnstampableNotifierJob` job when a new file is added" do
        expect do
          installment.save_files!([{ external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pic.jpg" }])
        end.to change { installment.product_files.alive.count }.by(1)

        expect(PdfUnstampableNotifierJob.jobs.size).to eq(0)
      end

      it "does not enqueue a `PdfUnstampableNotifierJob` job when a file is removed" do
        installment.save_files!([{ external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pic.jpg" }])

        expect do
          installment.save_files!([])
        end.to change { installment.product_files.alive.count }.by(-1)

        expect(PdfUnstampableNotifierJob.jobs.size).to eq(0)
      end

      it "generates the product files archive" do
        expect do
          installment.save_files!([{ external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pic.jpg" }])
        end.to change { installment.product_files.alive.count }.by(1)

        expect(installment.product_files_archives.size).to eq(1)
        expect(installment.product_files_archives.alive.size).to eq(1)
        expect(installment.product_files_archives.alive.first.url.split("/").last).to include(installment.name.split(" ").first)
      end
    end
  end

  describe "#folder_to_files_mapping" do
    it "returns an empty hash when there aren't folders with files" do
      file1 = create(:product_file, display_name: "First file")
      product = create(:product)
      product.product_files = [file1]

      create(:rich_content, entity: product, title: "Page 1", description: [
               { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
             ])
      create(:rich_content, entity: product, title: "Page 2", description: [
               { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ignore me" }] },
             ])

      expect(product.folder_to_files_mapping).to eq({})
    end

    it "returns the proper mapping when there are folders with files" do
      file1 = create(:product_file, display_name: "First file")
      file2 = create(:product_file, display_name: "Second file")
      file3 = create(:product_file, display_name: "Third file")
      file4 = create(:product_file, display_name: "Fourth file")
      product = create(:product)
      product.product_files = [file1, file2, file3, file4]
      product.save!
      page2_folder1 = { "name" => "", "uid" => SecureRandom.uuid }
      page2_folder2 = { "name" => "", "uid" => SecureRandom.uuid }
      create(:rich_content, entity: product, title: "Page 1", description: [
               { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
             ])
      create(:rich_content, entity: product, title: "Page 2", description: [
               { "type" => "fileEmbedGroup", "attrs" => page2_folder1, "content" => [
                 { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
               ] },
               { "type" => "fileEmbedGroup", "attrs" => page2_folder2, "content" => [
                 { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
                 { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
               ] },
             ])

      expect(product.folder_to_files_mapping).to eq(
        page2_folder1["uid"] => [file2.id],
        page2_folder2["uid"] => [file3.id, file4.id],
      )
    end
  end

  describe "#generate_folder_archives!" do
    it "generates folder archives for valid folders in the rich content" do
      file1 = create(:product_file, display_name: "First file")
      file2 = create(:product_file, display_name: "Second file")
      file3 = create(:product_file, display_name: "Third file")
      file4 = create(:product_file, display_name: "Fourth file")
      file5 = create(:product_file, display_name: "Fifth file")
      file6 = create(:product_file, display_name: "Sixth file")
      product = create(:product)
      product.product_files = [file1, file2, file3, file4, file5, file6]
      product.save!
      create(:rich_content, entity: product, title: "Page 1", description: [
               { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
             ])
      create(:rich_content, entity: product, title: "Page 2", description: [
               # This won't have a folder archive since it contains only one file embed
               { "type" => "fileEmbedGroup", "attrs" => { "name" => "", "uid" => SecureRandom.uuid }, "content" => [
                 { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
               ] },
               { "type" => "fileEmbedGroup", "attrs" => { "name" => "", "uid" => SecureRandom.uuid }, "content" => [
                 { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
                 { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
               ] },
               { "type" => "fileEmbedGroup", "attrs" => { "name" => "", "uid" => SecureRandom.uuid }, "content" => [
                 { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
                 { "type" => "fileEmbed", "attrs" => { "id" => file6.external_id, "uid" => SecureRandom.uuid } },
               ] }
             ])

      expect { product.generate_folder_archives! }.to change { product.product_files_archives.folder_archives.alive.count }.from(0).to(2)
    end

    it "regenerates file group archives containing the provided files" do
      product = create(:product)
      file1 = create(:product_file, link: product)
      file2 = create(:product_file, link: product)
      folder_id = SecureRandom.uuid
      description = [
        { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder_id }, "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
        ] }]
      create(:rich_content, entity: product, description:)

      archive = product.product_files_archives.create!(folder_id:, product_files: product.product_files)
      archive.mark_in_progress!
      archive.mark_ready!

      expect { product.generate_folder_archives! }.to_not change { archive.reload.deleted? }
      expect { product.generate_folder_archives!(for_files: [file1]) }.to change { archive.reload.deleted? }.from(false).to(true)
      expect(product.product_files_archives.folder_archives.alive.size).to eq(1)
      expect(product.product_files_archives.folder_archives.alive.first.folder_id).to eq(folder_id)
    end
  end

  describe "#generate_entity_archive!" do
    it "generates an entity archive" do
      file1 = create(:product_file, display_name: "First file")
      file2 = create(:product_file, display_name: "Second file")
      installment = create(:installment, product_files: [file1, file2])

      expect { installment.generate_entity_archive! }.to change { installment.product_files_archives.entity_archives.alive.count }.from(0).to(1)
      expect(installment.product_files_archives.entity_archives.alive.last.product_files).to eq([file1, file2])
    end

    it "deletes the previous archive" do
      file1 = create(:product_file, display_name: "First file")
      file2 = create(:product_file, display_name: "Second file")
      installment = create(:installment, product_files: [file1, file2])

      archive = installment.product_files_archives.create!(product_files: installment.product_files)
      archive.mark_in_progress!
      archive.mark_ready!

      expect { installment.generate_entity_archive! }.to_not change { installment.product_files_archives.entity_archives.alive.count }
      expect(archive.reload.alive?).to eq(false)
      expect(installment.product_files_archives.entity_archives.alive.last.product_files).to eq([file1, file2])
    end
  end

  describe "#has_files?" do
    it "returns false if product has no files" do
      product = create(:product)
      expect(product.has_files?).to eq(false)
    end

    it "returns true if product has alive files" do
      product = create(:product_with_pdf_files_with_size)
      expect(product.has_files?).to eq(true)

      product.product_files.each(&:mark_deleted!)
      expect(product.has_files?).to eq(false)
    end
  end

  describe "#has_been_transcoded?" do
    before do
      @product = create(:product)
      file_1 = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4")
      @product.product_files << file_1

      @transcoded_video = create(:transcoded_video, streamable: file_1, is_hls: true)
      @transcoded_video_2 = create(:transcoded_video, streamable: file_1, is_hls: true)
    end

    it "indicates that it has been transcoded if one of the transcoded videos are completed" do
      expect(@product.has_been_transcoded?).to be(true)

      @transcoded_video_2.update_column(:state, "processing")

      expect(@product.has_been_transcoded?).to be(true)
    end

    it "indicates that it hasn't been transcoded if none of the transcoded videos are completed" do
      @transcoded_video.update_column(:state, "processing")
      @transcoded_video_2.update_column(:state, "processing")

      expect(@product.has_been_transcoded?).to be(false)

      @transcoded_video.update_column(:state, "error")
      @transcoded_video_2.update_column(:state, "error")

      expect(@product.has_been_transcoded?).to be(false)

      not_yet_analyzed_product = create(:product)
      file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4")
      not_yet_analyzed_product.product_files << file
      expect(not_yet_analyzed_product.has_been_transcoded?).to be(false)
    end
  end

  describe "#transcode_videos!" do
    it "adds delay if there are too many videos", :freeze_time do
      product = create(:product)
      files = create_list(:streamable_video, 7, link: product, analyze_completed: true)
      product.transcode_videos!(first_batch_size: 5)

      files.first(5).each do |file|
        expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(file.id, "ProductFile").immediately
      end
      expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(files[5].id, "ProductFile").at((5 * 5).minutes.from_now)
      expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(files[6].id, "ProductFile").at((6 * 5).minutes.from_now)
    end
  end
end
