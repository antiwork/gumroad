# frozen_string_literal: true

require "spec_helper"

describe ProductFilesArchive do
  describe "callbacks" do
    it "saves `digest` when transitioning to the 'in_progress' state" do
      product = create(:product_with_files)
      product_files_archive = product.product_files_archives.create!(product_files: product.product_files)

      expect do
        product_files_archive.mark_in_progress
      end.to change { product_files_archive.reload.digest.present? }.to(true)
    end
  end

  describe "#belongs_to_product_or_installment_or_variant" do
    before do
      @product = create(:product)
      @variant = create(:variant)
      @installment = create(:installment)
    end

    def assert_no_errors(archive)
      expect(archive.valid?).to eq true
      expect(archive.errors.full_messages).to eq([])
    end

    def assert_errors(archive)
      expect(archive.valid?).to eq false
      expect(archive.errors.full_messages).to include(/A product files archive needs to belong to an installment, a product or a variant/)
    end

    it "raises no errors if only one of link/variant/installment is present" do
      assert_no_errors(build(:product_files_archive, link: @product))
      assert_no_errors(build(:product_files_archive, variant: @variant, link: nil))
      assert_no_errors(build(:product_files_archive, installment: @installment, link: nil))
    end

    it "raises an error if there are no associations or more associations than expected" do
      assert_errors(build(:product_files_archive, link: nil))
      assert_errors(build(:product_files_archive, link: @product, installment: @installment))
      assert_errors(build(:product_files_archive, link: nil, variant: @variant, installment: @installment))
      assert_errors(build(:product_files_archive, variant: @variant, link: @product))
      assert_errors(build(:product_files_archive, link: @product, variant: @variant, installment: @installment))
    end
  end

  describe ".latest_ready_entity_archive" do
    it "returns the correct entity archive" do
      product = create(:product)
      file1 = create(:product_file, display_name: "File 1")
      file2 = create(:product_file, display_name: "File 2")
      file3 = create(:product_file, display_name: "File 3")
      file4 = create(:product_file, display_name: "File 4")
      product.product_files = [file1, file2, file3, file4]

      description = [
        { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => SecureRandom.uuid }, "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
        ] },
        { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 2", "uid" => SecureRandom.uuid }, "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
        ] }]

      create(:rich_content, entity: product, description:)

      archive1 = product.product_files_archives.create!(product_files: [file1, file2])

      archive1.mark_in_progress!
      expect(product.product_files_archives.latest_ready_entity_archive).to eq(nil)

      archive1.mark_ready!
      expect(product.product_files_archives.latest_ready_entity_archive).to eq(archive1)

      archive2 = product.product_files_archives.create!(product_files: [file1, file2])
      expect(product.product_files_archives.latest_ready_entity_archive).to eq(archive1)

      archive1.mark_deleted!
      expect(product.product_files_archives.latest_ready_entity_archive).to eq(nil)

      archive2.mark_in_progress!
      expect(product.product_files_archives.latest_ready_entity_archive).to eq(nil)

      archive2.mark_ready!
      expect(product.product_files_archives.latest_ready_entity_archive).to eq(archive2)
    end
  end

  describe ".latest_ready_folder_archive" do
    it "returns the correct folder archive" do
      product = create(:product)
      file1 = create(:product_file, display_name: "File 1")
      file2 = create(:product_file, display_name: "File 2")
      file3 = create(:product_file, display_name: "File 3")
      file4 = create(:product_file, display_name: "File 4")
      product.product_files = [file1, file2, file3, file4]

      folder1_id = SecureRandom.uuid
      folder2_id = SecureRandom.uuid
      description =
        [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
        ] },
         { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 2", "uid" => folder2_id }, "content" => [
           { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
           { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
         ] }]

      create(:rich_content, entity: product, description:)

      archive1 = product.product_files_archives.create!(folder_id: folder1_id, product_files: [file1, file2])
      archive2 = product.product_files_archives.create!(folder_id: folder2_id, product_files: [file3, file4])

      archive1.mark_in_progress!
      expect(product.product_files_archives.latest_ready_folder_archive(folder1_id)).to eq(nil)
      archive1.mark_ready!
      expect(product.product_files_archives.latest_ready_folder_archive(folder1_id)).to eq(archive1)

      archive2.mark_in_progress!
      expect(product.product_files_archives.latest_ready_folder_archive(folder2_id)).to eq(nil)
      archive2.mark_ready!
      expect(product.product_files_archives.latest_ready_folder_archive(folder2_id)).to eq(archive2)

      archive2.mark_deleted!
      expect(product.product_files_archives.latest_ready_folder_archive(folder2_id)).to eq(nil)

      new_archive2 = product.product_files_archives.create!(folder_id: folder2_id, product_files: [file3, file4])
      new_archive2.mark_in_progress!
      expect(product.product_files_archives.latest_ready_folder_archive(folder2_id)).to eq(nil)

      new_archive2.mark_ready!
      expect(product.product_files_archives.latest_ready_folder_archive(folder2_id)).to eq(new_archive2)
    end
  end

  describe "#folder_archive?" do
    it "only returns true for folder archives" do
      product = create(:product)
      file1 = create(:product_file, display_name: "File 1")
      file2 = create(:product_file, display_name: "File 2")
      file3 = create(:product_file, display_name: "File 3")
      file4 = create(:product_file, display_name: "File 4")
      file5 = create(:product_file, display_name: "File 5")
      product.product_files = [file1, file2, file3, file4, file5]

      folder1_id = SecureRandom.uuid
      folder2_id = SecureRandom.uuid
      page1_description =
        [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
        ] },
         { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ignore me" }] }]

      page2_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 2", "uid" => folder2_id }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
      ] }]
      create(:rich_content, entity: product, description: page1_description)
      create(:rich_content, entity: product, description: page2_description)

      folder1_archive = product.product_files_archives.create!(folder_id: folder1_id, product_files: [file1, file2])
      folder2_archive = product.product_files_archives.create!(folder_id: folder2_id, product_files: [file3, file4, file5])
      entity_archive = product.product_files_archives.create!(product_files: [file3, file4, file5])

      post = create(:installment, product_files: [create(:product_file), create(:product_file)])
      installment_archive = post.product_files_archives.create!(product_files: post.product_files)

      variant = create(:variant, product_files: [create(:product_file), create(:product_file)])
      variant_archive = variant.product_files_archives.create(product_files: variant.product_files)

      expect(folder1_archive.folder_archive?).to eq(true)
      expect(folder2_archive.folder_archive?).to eq(true)
      expect(entity_archive.folder_archive?).to eq(false)
      expect(installment_archive.folder_archive?).to eq(false)
      expect(variant_archive.folder_archive?).to eq(false)
    end
  end

  describe "#files_digest" do
    context "when there is no rich content" do
      it "returns the correct digest" do
        product = create(:product)
        folder_1 = create(:product_folder, link: product, name: "folder 1")
        folder_2 = create(:product_folder, link: product, name: "folder 2")

        file_1 = create(:product_file, link: product, description: "pencil", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png", folder_id: folder_1.id)
        file_2 = create(:product_file, link: product, description: "manual", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf", folder_id: folder_2.id)
        file_3 = create(:product_file, link: product, description: "file without a folder", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf", folder_id: nil)

        archive = product.product_files_archives.create!(product_files: product.product_files)

        expect { archive.mark_in_progress }.to change { archive.reload.digest.present? }.to(true)

        expect(archive.digest).to eq(Digest::SHA1.hexdigest([
          "#{file_1.folder.external_id}/#{file_1.folder.name}/#{file_1.external_id}/#{file_1.name_displayable}",
          "#{file_2.folder.external_id}/#{file_2.folder.name}/#{file_2.external_id}/#{file_2.name_displayable}",
          "#{file_3.external_id}/#{file_3.name_displayable}"].sort.join("\n")))

        archive_copy = product.product_files_archives.create!(product_files: product.product_files)

        expect { archive_copy.mark_in_progress }.to change { archive_copy.reload.digest.present? }.to(true)

        # Ensure digests produce consistent results
        expect(archive.digest).to eq(archive_copy.digest)
      end
    end

    context "entity archives" do
      it "returns the same digest when nothing has changed" do
        product = create(:product_with_files)
        archive1 = product.product_files_archives.create!(product_files: product.product_files)

        expect { archive1.mark_in_progress }.to change { archive1.reload.digest.present? }.to(true)

        archive2 = product.product_files_archives.create!(product_files: product.product_files)
        expect { archive2.mark_in_progress }.to change { archive2.reload.digest.present? }.to(true)

        expect(archive1.digest).to eq(archive2.digest)
      end

      it "returns the correct digest" do
        product = create(:product)
        file1 = create(:product_file, display_name: "File 1")
        file2 = create(:product_file, display_name: "File 2")
        file3 = create(:product_file, display_name: "File 3")
        file4 = create(:product_file, display_name: "File 4")
        file5 = create(:product_file, display_name: "File 5")
        product.product_files = [file1, file2, file3, file4, file5]

        folder1_id = SecureRandom.uuid
        folder2_id = SecureRandom.uuid
        page1_description =
          [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
          ] },
           { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ignore me" }] }]

        page2_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 2", "uid" => folder2_id }, "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
        ] }]

        page1 = create(:rich_content, title: "Page 1", entity: product, description: page1_description)
        page2 = create(:rich_content, title: "Page 2", entity: product, description: page2_description)

        archive = product.product_files_archives.create!(product_files: [file1, file2, file3, file4, file5])
        expect { archive.mark_in_progress }.to change { archive.reload.digest.present? }.to(true)

        expect(archive.digest).to eq(Digest::SHA1.hexdigest([
          "#{page1.external_id}/Page 1/#{folder1_id}/folder 1/#{file1.external_id}/File 1",
          "#{page1.external_id}/Page 1/#{folder1_id}/folder 1/#{file2.external_id}/File 2",
          "#{page2.external_id}/Page 2/#{folder2_id}/folder 2/#{file3.external_id}/File 3",
          "#{page2.external_id}/Page 2/#{folder2_id}/folder 2/#{file4.external_id}/File 4",
          "#{page2.external_id}/Page 2/#{folder2_id}/folder 2/#{file5.external_id}/File 5"].sort.join("\n")))

        archive2 = product.product_files_archives.create!(product_files: [file1, file2, file3, file4, file5])
        expect { archive2.mark_in_progress }.to change { archive2.reload.digest.present? }.to(true)

        # Ensure digests produce consistent results
        expect(archive.digest).to eq(archive2.digest)
      end
    end

    context "folder archives" do
      it "returns the correct digests" do
        product = create(:product)
        file1 = create(:product_file, display_name: "File 1")
        file2 = create(:product_file, display_name: "File 2")
        file3 = create(:product_file, display_name: "File 3")
        file4 = create(:product_file, display_name: "File 4")
        file5 = create(:product_file, display_name: "File 5")
        product.product_files = [file1, file2, file3, file4, file5]

        folder1_id = SecureRandom.uuid
        folder2_id = SecureRandom.uuid
        description =
          [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
          ] },
           { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 2", "uid" => folder2_id }, "content" => [
             { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
             { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
             { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
           ] },
           { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ignore me" }] }]

        create(:rich_content, entity: product, description:)

        archive1 = product.product_files_archives.create!(folder_id: folder1_id, product_files: [file1, file2])
        expect { archive1.mark_in_progress }.to change { archive1.reload.digest.present? }.to(true)

        expect(archive1.digest).to eq(Digest::SHA1.hexdigest(["#{folder1_id}/folder 1/#{file1.external_id}/File 1", "#{folder1_id}/folder 1/#{file2.external_id}/File 2"].sort.join("\n")))

        archive2 = product.product_files_archives.create!(folder_id: folder2_id, product_files: [file3, file4, file5])
        expect { archive2.mark_in_progress }.to change { archive2.reload.digest.present? }.to(true)

        expect(archive2.digest).to eq(Digest::SHA1.hexdigest(["#{folder2_id}/folder 2/#{file3.external_id}/File 3", "#{folder2_id}/folder 2/#{file4.external_id}/File 4", "#{folder2_id}/folder 2/#{file5.external_id}/File 5"].sort.join("\n")))

        # Ensure digests produce consistent results
        archive1_copy = product.product_files_archives.create!(folder_id: folder1_id, product_files: [file1, file2])
        expect { archive1_copy.mark_in_progress }.to change { archive1_copy.reload.digest.present? }.to(true)
        expect(archive1.digest).to eq(archive1_copy.digest)

        archive2_copy = product.product_files_archives.create!(folder_id: folder2_id, product_files: [file3, file4, file5])
        expect { archive2_copy.mark_in_progress }.to change { archive2_copy.reload.digest.present? }.to(true)
        expect(archive2.digest).to eq(archive2_copy.digest)
      end
    end
  end

  context "scopes" do
    before do
      post = create(:installment)
      post.product_files = [create(:product_file), create(:product_file)]
      post.save!
      installment_archive = post.product_files_archives.create
      installment_archive.product_files = post.product_files
      installment_archive.save!

      variant = create(:variant)
      variant.product_files = [create(:product_file), create(:product_file)]
      variant.save!
      variant_archive = variant.product_files_archives.create
      variant_archive.product_files = variant.product_files
      variant_archive.save!

      product = create(:product)
      file1 = create(:product_file)
      file2 = create(:product_file)
      product.product_files = [file1, file2]
      product.save!

      folder1_id = SecureRandom.uuid
      create(:rich_content, entity: product, description: [
               { "type" => "fileEmbedGroup", "attrs" => { "name" => "Folder 1", "uid" => folder1_id }, "content" => [
                 { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
                 { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
               ] }
             ])
      product.product_files_archives.create!(product_files: product.product_files)
      product.product_files_archives.create!(folder_id: folder1_id, product_files: [file1, file2])
    end

    describe ".entity_archives" do
      it "only returns entity archives" do
        expect(ProductFilesArchive.entity_archives.count).to eq(3)
        expect(ProductFilesArchive.entity_archives.any?(&:folder_archive?)).to eq(false)
      end
    end

    describe ".folder_archives" do
      it "only returns folder archives" do
        expect(ProductFilesArchive.folder_archives.count).to eq(1)
        expect(ProductFilesArchive.folder_archives.first.folder_archive?).to eq(true)
      end
    end
  end

  it "has an initial status of queueing" do
    expect(build(:product_files_archive).send(:product_files_archive_state)).to eq("queueing")
  end

  it "is create-able through a link" do
    link = create(:product)
    link.product_files << create(:product_file)
    link.product_files << create(:product_file)
    link.save

    product_files_archive = link.product_files_archives.create
    product_files_archive.product_files = link.product_files
    product_files_archive.save

    expect(product_files_archive.product_files.count).to eq(2)
    expect(product_files_archive.class.name).to eq("ProductFilesArchive")
    expect(product_files_archive.product_files_archive_state).to eq("queueing")
    expect(product_files_archive.link).to be(link)
    expect(product_files_archive.installment).to be_nil
    expect(product_files_archive.product_files.to_a).to eq(link.product_files.to_a)
    expect(product_files_archive.variant).to be_nil
  end

  it "is create-able through an installment" do
    post = create(:installment)
    post.product_files << create(:product_file)
    post.product_files << create(:product_file)
    post.product_files << create(:product_file)
    post.save

    product_files_archive = post.product_files_archives.create
    product_files_archive.product_files = post.product_files
    product_files_archive.save

    expect(product_files_archive.product_files.count).to eq(3)
    expect(product_files_archive.class.name).to eq("ProductFilesArchive")
    expect(product_files_archive.product_files_archive_state).to eq("queueing")
    expect(product_files_archive.installment).to be(post)
    expect(product_files_archive.link).to be_nil
    expect(product_files_archive.product_files.to_a).to eq(post.product_files.to_a)
    expect(product_files_archive.variant).to be_nil
  end

  it "is create-able through a variant" do
    variant = create(:variant)
    variant.product_files << create(:product_file)
    variant.product_files << create(:product_file)
    variant.save!

    product_files_archive = variant.product_files_archives.create
    product_files_archive.product_files = variant.product_files
    product_files_archive.save!

    expect(product_files_archive.product_files.count).to eq(2)
    expect(product_files_archive.class.name).to eq("ProductFilesArchive")
    expect(product_files_archive.product_files_archive_state).to eq("queueing")
    expect(product_files_archive.variant).to be(variant)
    expect(product_files_archive.installment).to be_nil
    expect(product_files_archive.link).to be_nil
    expect(product_files_archive.product_files.to_a).to eq(variant.product_files.to_a)
  end

  it "schedules an UpdateProductFilesArchiveWorker job" do
    link = create(:product)
    link.product_files << create(:product_file)
    link.product_files << create(:product_file)
    link.save

    product_files_archive = link.product_files_archives.create
    product_files_archive.product_files = link.product_files
    product_files_archive.save!
    expect(UpdateProductFilesArchiveWorker).to have_enqueued_sidekiq_job(product_files_archive.id)
  end

  describe "#has_cdn_url?" do
    it "returns a truthy value when the CDN URL is in a specific format" do
      product_files_archive = create(:product_files_archive)

      expect(product_files_archive.has_cdn_url?).to be_truthy
    end

    it "returns a falsey value when the CDN URL is not in the regular Gumroad format" do
      product_files_archive = build(:product_files_archive, url: "https:/unknown.com/manual.pdf")

      expect(product_files_archive.has_cdn_url?).to be_falsey
    end
  end

  context "when s3 directory is empty" do
    it "has unique s3_key for the same product" do
      product = create(:product)

      product_files_archives = create_list(:product_files_archive, 2, link: product)

      s3_double = double
      allow(s3_double).to receive(:list_objects).times.and_return([])
      allow(Aws::S3::Client).to receive(:new).and_return(s3_double)

      expect(product_files_archives.first.s3_key).not_to eq(product_files_archives.last.s3_key)
    end
  end

  describe "#s3_directory_uri" do
    it "is unique for different archives of the same product" do
      product = create(:product)
      archives = create_list(:product_files_archive, 2, link: product)
      expect(archives.first.s3_directory_uri).not_to eq(archives.last.s3_directory_uri)
    end
  end

  describe "#set_url_if_not_present" do
    it "sets the url if not present" do
      product = create(:product)
      product_files_archive = create(:product_files_archive_without_url, link: product)
      product_files_archive.set_url_if_not_present
      expect(product_files_archive.url).to start_with("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments_zipped/")
      expect(product_files_archive.url.split("/").last).to eq("The_Works_of_Edgar_Gumstein.zip")
    end
  end

  describe "#construct_url" do
    it "uses the entity name for an entity archive" do
      product = create(:product, name: "Product name")
      entity_archive = create(:product_files_archive_without_url, link: product)
      entity_archive.set_url_if_not_present

      expect(entity_archive.url).to start_with("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments_zipped/")
      expect(entity_archive.url.split("/").last).to eq("Product_name.zip")
    end

    it "uses the folder name for a folder archive" do
      product = create(:product)
      file1 = create(:product_file)
      file2 = create(:product_file)
      product.product_files = [file1, file2]

      folder_id = SecureRandom.uuid
      create(:rich_content, entity: product, description: [
               { "type" => "fileEmbedGroup", "attrs" => { "name" => "Folder 1", "uid" => folder_id }, "content" => [
                 { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
                 { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
               ] }
             ])
      folder_archive = create(:product_files_archive_without_url, link: product, folder_id:, product_files: [file1, file2])
      folder_archive.set_url_if_not_present

      expect(folder_archive.url).to start_with("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments_zipped/")
      expect(folder_archive.url.split("/").last).to eq("Folder_1.zip")
    end
  end

  describe "#needs_updating?" do
    before do
      @product = create(:product)
      @product_file1 = create(:product_file, display_name: "First file")
      @product_file2 = create(:product_file, display_name: "Second file")
      @product_file3 = create(:product_file, display_name: "Third file")
      @product_file4 = create(:product_file, display_name: "Fourth file")
      @product_file5_name = "Fifth file"
      @product_file5 = create(:product_file, display_name: @product_file5_name)
      @product.product_files = [@product_file1, @product_file2, @product_file3, @product_file4, @product_file5]
      @product.save!

      folder1_uid = SecureRandom.uuid
      @page1 = create(:rich_content, entity: @product, description: [
                        { "type" => "fileEmbed", "attrs" => { "id" => @product_file1.external_id, "uid" => "64e84875-c795-567c-d2dd-96336ab093d5" } },
                      ])
      @page2 = create(:rich_content, entity: @product, title: "Page 2", description: [
                        { "type" => "fileEmbedGroup", "attrs" => { "name" => "", "uid" => folder1_uid }, "content" => [
                          { "type" => "fileEmbed", "attrs" => { "id" => @product_file2.external_id, "uid" => "0c042930-2df1-4583-82ef-a63172138683" } },
                        ] },
                        { "type" => "fileEmbedGroup", "attrs" => { "name" => "" }, "content" => [
                          { "type" => "fileEmbed", "attrs" => { "id" => @product_file3.external_id, "uid" => "0c042930-2df1-4583-82ef-a6317213868f" } },
                        ] },
                      ])
      @page3 = create(:rich_content, entity: @product, description: [
                        { "type" => "fileEmbedGroup", "attrs" => { "name" => "Folder 3" }, "content" => [
                          { "type" => "fileEmbed", "attrs" => { "id" => @product_file4.external_id, "uid" => "0c042930-2df1-4583-82ef-a6317213868w" } },
                          { "type" => "fileEmbed", "attrs" => { "id" => @product_file5.external_id, "uid" => "0c042930-2df1-4583-82ef-a63172138681" } },
                        ] },
                      ])
      @product_files_archive = @product.product_files_archives.create
      @product_files_archive.product_files = @product.product_files
      @product_files_archive.mark_in_progress!
      @product_files_archive.mark_ready!

      @folder1_archive = @product.product_files_archives.create(folder_id: folder1_uid)
      @folder1_archive.product_files = [@product_file2, @product_file3]
      @folder1_archive.mark_in_progress!
      @folder1_archive.mark_ready!

      @files = @product_files_archive.product_files.archivable
    end

    it "returns false when the files and folders in the rich content are unchanged" do
      expect(@product_files_archive.needs_updating?(@files)).to be(false)
    end

    it "returns true when a file changes but the filename stays the same" do
      folder_id = SecureRandom.uuid
      archive = @product.product_files_archives.create(folder_id:, product_files: [@product_file4, @product_file5])
      archive.mark_in_progress!
      archive.mark_ready!

      description = [
        { "type" => "fileEmbedGroup", "attrs" => { "name" => "Folder 3", "uid" => folder_id }, "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => @product_file4.external_id, "uid" => "0c042930-2df1-4583-82ef-a6317213868w" } },
          { "type" => "fileEmbed", "attrs" => { "id" => create(:product_file, link: @product, display_name: @product_file5_name).external_id, "uid" => SecureRandom.uuid } },
        ] },
      ]
      @page3.update!(description:)
      @product_file5.mark_deleted!

      expect(ProductFilesArchive.find(archive.id).needs_updating?(@product.product_files.alive)).to be(true)
    end

    it "returns true when a file is renamed" do
      @product_file1.update!(display_name: "New file name")

      expect(@product_files_archive.reload.needs_updating?(@files)).to be(true)
    end

    it "returns true when a page containing files is renamed" do
      @page1.update!(title: "New title")

      expect(@product_files_archive.reload.needs_updating?(@files)).to be(true)
    end

    it "returns true when a page containing files is deleted" do
      @page1.mark_deleted!

      expect(@product_files_archive.reload.needs_updating?(@files)).to be(true)
    end

    it "returns true when a page is added containing files" do
      @product_file6 = create(:product_file, display_name: "Sixth file")
      @product.product_files << @product_file6
      @product_files_archive.product_files << @product_file6
      create(:rich_content, entity: @product, description: [
               { "type" => "fileEmbed", "attrs" => { "id" => @product_file6.external_id, "uid" => "64e84875-c795-567c-d2dd-96336ab093fg" } },
             ])

      expect(@product_files_archive.reload.needs_updating?(@product_files_archive.product_files.not_external_link.not_stream_only.in_order)).to be(true)
    end

    it "returns false when a page is added without files" do
      create(:rich_content, entity: @product, description: [
               { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "This is a paragraph" }] },
             ])

      expect(@product_files_archive.reload.needs_updating?(@files)).to be(false)
    end

    it "returns true when a file group's name is changed" do
      @page3.description.first["attrs"] = { "name" => "New folder name", "uid" => SecureRandom.uuid }
      @page3.save!

      expect(@product_files_archive.reload.needs_updating?(@files)).to be(true)
    end

    it "returns true when a file group is deleted" do
      @page3.description.delete_at(0)
      @page3.save!

      expect(@product_files_archive.reload.needs_updating?(@files)).to be(true)
    end

    it "returns true when a file group is added" do
      @product_file6 = create(:product_file, display_name: "Sixth file")
      @product.product_files << @product_file6
      @product_files_archive.product_files << @product_file6
      @page3.description << { "type" => "fileEmbedGroup", "attrs" => { "name" => "New folder", "uid" => SecureRandom.uuid }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => @product_file6.external_id, "uid" => SecureRandom.uuid } },
      ] }
      @page3.save!

      expect(@product_files_archive.reload.needs_updating?(@files)).to be(true)
    end

    it "returns true when a file is added to a file group" do
      @product_file6 = create(:product_file, display_name: "Sixth file")
      @product.product_files << @product_file6
      @product_files_archive.product_files << @product_file6
      @page3.description.first["content"] << { "type" => "fileEmbed", "attrs" => { "id" => @product_file6.external_id, "uid" => SecureRandom.uuid } }
      @page3.save!

      expect(@product_files_archive.reload.needs_updating?(@files)).to be(true)
    end

    it "returns true when a file is removed from a file group" do
      @page3.description.first["content"].delete_at(0)
      @page3.save!

      expect(@product_files_archive.reload.needs_updating?(@files)).to be(true)
    end

    it "returns true when a file is moved from one file group to another" do
      @page2.description.first["content"] << @page3.description.last["content"].delete_at(0)
      @page2.save!
      @page3.save!

      expect(@product_files_archive.reload.needs_updating?(@files)).to be(true)
    end

    it "returns true when a file is moved out of a file group " do
      @page3.description << @page3.description.last["content"].delete_at(0)
      @page3.save!

      expect(@product_files_archive.reload.needs_updating?(@files)).to be(true)
    end

    it "returns false when a file is reordered within a file group" do
      @page3.description.first["content"].reverse!
      @page3.save!

      expect(@product_files_archive.reload.needs_updating?(@files)).to be(false)
    end

    context "folder archives" do
      it "returns false when no changes" do
        expect(@folder1_archive.reload.needs_updating?(@files)).to be(false)
      end

      it "returns false on page name changes" do
        @page1.update!(title: "Not even the same page!")
        @page2.update!(title: "New title!")
        @page3.update!(title: "pg3")

        expect(@folder1_archive.reload.needs_updating?(@files)).to be(false)
      end

      it "returns false when unrelated folders change" do
        rich_content = RichContent.find_by(id: @page2.id)
        rich_content.description.second["attrs"]["name"] = "New folder name!"
        rich_content.save!

        rich_content = RichContent.find_by(id: @page3.id)
        rich_content.description.first["attrs"]["name"] = "New folder name!"
        rich_content.save!

        expect(@folder1_archive.reload.needs_updating?(@files)).to be(false)
      end

      it "returns false when top-level files are modified" do
        @product_file1.update!(display_name: "a new name")

        expect(@folder1_archive.reload.needs_updating?(@files)).to be(false)
      end

      it "returns true when files are added" do
        @product_file6 = create(:product_file, display_name: "Sixth file")
        @product.product_files << @product_file6

        @page2.description.first["content"] << { "type" => "fileEmbed", "attrs" => { "id" => @product_file6.external_id, "uid" => SecureRandom.uuid } }
        @page2.save!

        expect(@folder1_archive.reload.needs_updating?(@product.product_files)).to be(true)
      end

      it "returns true when folder files are deleted" do
        @product.product_files.find_by(id: @product_file2.id).mark_deleted!
        @product.save!

        rich_content = RichContent.find_by(id: @page2.id)
        rich_content.description = [rich_content.description.second]
        rich_content.save!

        expect(@folder1_archive.reload.needs_updating?(@product.product_files)).to be(true)
      end

      it "returns true if the folder name changes" do
        rich_content = RichContent.find_by(id: @page2.id)
        rich_content.description.first["attrs"]["name"] = "New folder name!"
        rich_content.save!

        expect(@folder1_archive.reload.needs_updating?(@files)).to be(true)
      end
    end
  end

  describe "#rich_content_provider" do
    context "when associated with a product" do
      it "returns the associated product" do
        product_files_archive = create(:product_files_archive)

        expect(product_files_archive.rich_content_provider).to eq(product_files_archive.link)
      end
    end

    context "when associated with a variant" do
      it "returns the associated variant" do
        product_files_archive = create(:product_files_archive, link: nil, variant: create(:variant))

        expect(product_files_archive.rich_content_provider).to eq(product_files_archive.variant)
      end
    end

    context "when associated with an installment" do
      it "returns nil" do
        product_files_archive = create(:product_files_archive, installment: create(:installment), link: nil)

        expect(product_files_archive.rich_content_provider).to be_nil
      end
    end
  end
end
