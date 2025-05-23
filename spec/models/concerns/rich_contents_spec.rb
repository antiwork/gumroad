# frozen_string_literal: true

require "spec_helper"

describe RichContents do
  let(:description) { [{ "type" => "paragraph", "content" => [{ "text" => Faker::Lorem.unique.sentence, "type" => "text" }] }] }

  context "for a product" do
    let(:product) { create(:product) }

    describe "#rich_content_json" do
      context "when product has rich content" do
        let!(:rich_content1) { create(:rich_content, entity: product, description:, title: "Page 1", position: 3) }
        let!(:rich_content2) { create(:rich_content, entity: product, description:, title: "Deleted page 2", deleted_at: 1.day.ago, position: 0) }
        let!(:rich_content3) { create(:rich_content, entity: product, description:, title: "Page 3", position: 1) }
        let!(:another_product_rich_content) { create(:rich_content, description:, title: "Another product's page", position: 2) }

        it "returns the product-level alive rich contents in order" do
          expect(product.rich_content_json).to eq([
                                                    { id: rich_content3.external_id, page_id: rich_content3.external_id, variant_id: nil, title: "Page 3", description: { type: "doc", content: rich_content3.description }, updated_at: rich_content3.updated_at },
                                                    { id: rich_content1.external_id, page_id: rich_content1.external_id, variant_id: nil, title: "Page 1", description: { type: "doc", content: rich_content1.description }, updated_at: rich_content1.updated_at }
                                                  ])
        end

        context "when `has_same_rich_content_for_all_variants` is true" do
          before do
            product.update!(has_same_rich_content_for_all_variants: true)
          end

          it "returns the product-level alive rich contents" do
            expect(product.rich_content_json).to eq([
                                                      { id: rich_content3.external_id, page_id: rich_content3.external_id, variant_id: nil, title: "Page 3", description: { type: "doc", content: rich_content3.description }, updated_at: rich_content3.updated_at },
                                                      { id: rich_content1.external_id, page_id: rich_content1.external_id, variant_id: nil, title: "Page 1", description: { type: "doc", content: rich_content1.description }, updated_at: rich_content1.updated_at }
                                                    ])
          end
        end
      end

      context "when product does not have rich content" do
        it "returns empty array" do
          expect(product.rich_content_json).to eq([])
        end
      end
    end

    describe "#rich_content_folder_name" do
      it "returns the folder name when the corresponding folder exists in the rich content" do
        file1 = create(:product_file, display_name: "File 1")
        file2 = create(:product_file, display_name: "File 2")
        file3 = create(:product_file, display_name: "File 3")
        file4 = create(:product_file, display_name: "File 4")
        file5 = create(:product_file, display_name: "File 5")
        product.product_files = [file1, file2, file3, file4, file5]

        folder1_id = SecureRandom.uuid
        folder2_id = SecureRandom.uuid
        create(:rich_content, entity: product, title: "Page 1", description: [], position: 0)

        expect(product.rich_content_folder_name(folder1_id)).to eq (nil)
        expect(product.rich_content_folder_name(folder2_id)).to eq (nil)

        page2_description = [
          { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
          ] },
          { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ignore me" }] }]

        page3_description = [
          {
            "type" => "fileEmbedGroup",
            # Ensure folders with numeric names are handled as strings
            "attrs" => { "name" => 100, "uid" => folder2_id },
            "content" => [
              { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
              { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
              { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
            ]
          }
        ]

        create(:rich_content, entity: product, title: "Page 2", description: page2_description, position: 1)
        create(:rich_content, entity: product, title: "Page 3", description: page3_description, position: 2)

        expect(product.reload.rich_content_folder_name(folder1_id)).to eq ("folder 1")
        expect(product.reload.rich_content_folder_name(folder2_id)).to eq ("100")
      end
    end
  end

  context "for a variant" do
    let(:variant_category) { create(:variant_category) }
    let(:variant) { create(:variant, variant_category:) }

    describe "#rich_content_json" do
      context "when variant has rich content" do
        let!(:rich_content1) { create(:rich_content, entity: variant, description:, title: "Page 1", position: 3) }
        let!(:rich_content2) { create(:rich_content, entity: variant, description:, title: "Deleted page 2", deleted_at: 1.day.ago, position: 0) }
        let!(:rich_content3) { create(:rich_content, entity: variant, description:, title: "Page 3", position: 1) }
        let!(:another_variant_rich_content) { create(:rich_content, entity: create(:variant, variant_category:), description:, title: "Another variant's page", position: 2) }

        it "returns the variant-level alive rich contents" do
          expect(variant.rich_content_json).to eq([
                                                    { id: rich_content3.external_id, page_id: rich_content3.external_id, variant_id: variant.external_id, title: "Page 3", description: { type: "doc", content: rich_content3.description }, updated_at: rich_content3.updated_at },
                                                    { id: rich_content1.external_id, page_id: rich_content1.external_id, variant_id: variant.external_id, title: "Page 1", description: { type: "doc", content: rich_content1.description }, updated_at: rich_content1.updated_at }
                                                  ])
        end

        context "when corresponding product's `has_same_rich_content_for_all_variants` is true" do
          before do
            variant_category.link.update!(has_same_rich_content_for_all_variants: true)
          end

          it "returns empty array" do
            expect(variant.rich_content_json).to eq([])
          end
        end
      end

      context "when variant does not have rich content" do
        it "returns empty array" do
          expect(variant.rich_content_json).to eq([])
        end
      end
    end
  end
end
