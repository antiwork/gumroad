# frozen_string_literal: true

require "spec_helper"

describe DeleteProductFilesArchivesWorker do
  before do
    @product = create(:product, user: create(:named_seller))
    product_file_1 = create(:product_file, link: @product)
    product_file_2 = create(:product_file, link: @product)
    product_file_3 = create(:product_file, link: @product)
    product_file_4 = create(:product_file, link: @product)

    folder1_id = SecureRandom.uuid
    folder2_id = SecureRandom.uuid
    product_page_description = [
      { "type" => "fileEmbedGroup", "attrs" => { "name" => "", "uid" => folder1_id }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => product_file_1.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => product_file_2.external_id, "uid" => SecureRandom.uuid } },
      ] },
      { "type" => "fileEmbedGroup", "attrs" => { "name" => "", "uid" => folder2_id }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => product_file_3.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => product_file_4.external_id, "uid" => SecureRandom.uuid } },
      ] }]
    create(:rich_content, entity: @product, title: "Page 1", description: product_page_description)

    product_archive = @product.product_files_archives.create!
    product_archive.product_files = @product.product_files
    product_archive.mark_in_progress!
    product_archive.mark_ready!

    folder_archive1 = @product.product_files_archives.create!(folder_id: folder1_id)
    folder_archive1.product_files = [product_file_1, product_file_2]
    folder_archive1.mark_in_progress!
    folder_archive1.mark_ready!

    folder_archive2 = @product.product_files_archives.create!(folder_id: folder2_id)
    folder_archive2.product_files = [product_file_3, product_file_4]
    folder_archive2.mark_in_progress!
    folder_archive2.mark_ready!


    folder3_id = SecureRandom.uuid
    product_file_5 = create(:product_file)
    product_file_6 = create(:product_file)
    variant_category = create(:variant_category, title: "versions", link: @product)
    @variant = create(:variant, variant_category:, name: "mac")
    @variant.product_files = [product_file_5, product_file_6]
    variant_page_description = [
      { "type" => "fileEmbedGroup", "attrs" => { "name" => "", "uid" => folder3_id }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => product_file_5.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => product_file_6.external_id, "uid" => SecureRandom.uuid } },
      ] }]
    create(:rich_content, entity: @variant, title: "Variant Page 1", description: variant_page_description)

    variant_archive = @variant.product_files_archives.create!
    variant_archive.product_files = @variant.product_files
    variant_archive.mark_in_progress!
    variant_archive.mark_ready!

    variant_folder_archive = @variant.product_files_archives.create!(folder_id: folder3_id)
    variant_folder_archive.product_files = [product_file_5, product_file_6]
    variant_folder_archive.mark_in_progress!
    variant_folder_archive.mark_ready!

    @total_product_archives = @product.product_files_archives.alive.ready.count
    @total_variant_archives = @variant.product_files_archives.alive.ready.count
  end

  describe ".perform" do
    context "when given a product_id" do
      it "deletes the corresponding product and variant archives when the product is deleted" do
        described_class.new.perform(@product.id, nil)

        expect(ProductFilesArchive.alive.count).to eq(@total_product_archives + @total_variant_archives)

        @product.mark_deleted!
        described_class.new.perform(@product.id, nil)

        expect(@product.product_files_archives.alive.count).to eq(0)
        expect(@variant.product_files_archives.alive.count).to eq(0)
      end
    end

    context "when given a variant_id" do
      it "deletes the corresponding variant archives when the variant is deleted" do
        described_class.new.perform(@variant.variant_category.link_id, @variant.id)
        expect(ProductFilesArchive.alive.count).to eq(@total_product_archives + @total_variant_archives)

        @variant.mark_deleted!
        described_class.new.perform(@variant.variant_category.link_id, @variant.id)

        expect(@product.product_files_archives.alive.count).to eq(@total_product_archives)
        expect(@variant.product_files_archives.alive.count).to eq(0)
      end
    end
  end
end
