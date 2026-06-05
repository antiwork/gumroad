# frozen_string_literal: true

require "spec_helper"

describe RichContent do
  describe "validations" do
    describe "description" do
      context "invalid descriptions" do
        let(:invalid_descriptions) { ["not valid", ["also not valid"], [{ "type" => 2 }]] }

        it "adds error when the description is invalid" do
          invalid_descriptions.each do |invalid_description|
            rich_content = build(:product_rich_content, description: invalid_description)
            expect(rich_content).to be_invalid
            expect(rich_content.errors.full_messages).to eq(["Content is invalid"])
          end
        end
      end

      context "valid descriptions" do
        let(:valid_descriptions) { [[], [{ "type": "text", "text": "Trace" }], [{ "type": "text", "text": "Trace" }, { "type": "text", "marks": [{ "type": "italic" }], "text": "Q" }]] }

        it "does not add errors for valid descriptions" do
          valid_descriptions.each do |valid_description|
            rich_content = build(:product_rich_content, description: valid_description)
            expect(rich_content).to be_valid
          end
        end
      end
    end
  end

  describe "#embedded_product_file_ids_in_order" do
    let(:product) { create(:product) }
    let(:rich_content) { create(:product_rich_content, entity: product) }

    it "returns the ids of the embedded product files in order" do
      file1 = create(:listenable_audio, link: product, position: 0)
      file2 = create(:product_file, link: product, position: 1, created_at: 2.days.ago)
      file3 = create(:readable_document, link: product, position: 2)
      file4 = create(:streamable_video, link: product, position: 3, created_at: 1.day.ago)
      file5 = create(:listenable_audio, link: product, position: 4, created_at: 3.days.ago)

      rich_content.update!(description: [
                             { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] },
                             { "type" => "image", "attrs" => { "src" => "https://example.com/album.jpg", "link" => nil } },
                             { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
                             { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "World" }] },
                             { "type" => "blockquote", "content" => [
                               { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Inside blockquote" }] },
                               { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
                             ] },
                             { "type" => "orderedList", "content" => [
                               { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ordered list item 1" }] }] },
                               { "type" => "listItem", "content" => [
                                 { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ordered list item 2" }] },
                                 { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
                               ] },
                               { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ordered list item 3" }] }] },
                             ] },
                             { "type" => "bulletList", "content" => [
                               { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Bullet list item 1" }] }] },
                               { "type" => "listItem", "content" => [
                                 { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Bullet list item 2" }] },
                                 { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
                               ] },
                               { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Bullet list item 3" }] }] },
                             ] },
                             { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Lorem ipsum" }] },
                             { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
                           ])

      expect(rich_content.embedded_product_file_ids_in_order).to eq([file2.id, file5.id, file1.id, file4.id, file3.id])
    end
  end

  describe "stripping cross-product file embeds on save" do
    let(:product) { create(:product) }
    let(:own_file) { create(:product_file, link: product) }
    let(:foreign_file) { create(:product_file, link: create(:product)) }

    def embed(file)
      { "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
    end

    it "removes embeds for files owned by another product from a product's content" do
      rich_content = create(:product_rich_content, entity: product, description: [embed(own_file), embed(foreign_file)])
      expect(rich_content.reload.embedded_product_file_ids_in_order).to eq([own_file.id])
    end

    it "removes foreign embeds from a variant's content" do
      variant = create(:variant, variant_category: create(:variant_category, link: product))
      rich_content = create(:rich_content, entity: variant, description: [embed(own_file), embed(foreign_file)])
      expect(rich_content.reload.embedded_product_file_ids_in_order).to eq([own_file.id])
    end

    it "preserves embeds for the product's own files" do
      another_own_file = create(:product_file, link: product)
      rich_content = create(:product_rich_content, entity: product, description: [embed(own_file), embed(another_own_file)])
      expect(rich_content.reload.embedded_product_file_ids_in_order).to match_array([own_file.id, another_own_file.id])
    end

    it "prunes a file embed group left empty after removing a foreign embed" do
      description = [{ "type" => "fileEmbedGroup", "attrs" => { "uid" => SecureRandom.uuid, "name" => "Files" }, "content" => [embed(foreign_file)] }]
      rich_content = create(:product_rich_content, entity: product, description:)
      expect(rich_content.reload.description).to eq([])
    end

    it "keeps own-product embeds inside a file embed group while dropping the foreign one" do
      description = [{ "type" => "fileEmbedGroup", "attrs" => { "uid" => SecureRandom.uuid, "name" => "Files" }, "content" => [embed(own_file), embed(foreign_file)] }]
      rich_content = create(:product_rich_content, entity: product, description:)
      expect(rich_content.reload.embedded_product_file_ids_in_order).to eq([own_file.id])
    end

    it "leaves content without foreign embeds untouched" do
      description = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }, embed(own_file)]
      rich_content = create(:product_rich_content, entity: product, description:)
      expect(rich_content.reload.description).to eq(description)
    end
  end

  describe "#has_license_key?" do
    let(:product) { create(:product) }

    it "returns false if it does not contain license key" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
      expect(rich_content.has_license_key?).to be(false)
    end

    it "returns true if it contains license key" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "licenseKey" }])
      expect(rich_content.has_license_key?).to be(true)
    end

    it "returns true if it contains license key nested inside a list item" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "orderedList", "content" => [{ "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ordered list item 2" }] }, { "type" => "licenseKey" }] }] }])
      expect(rich_content.has_license_key?).to be(true)
    end

    it "returns true if it contains license key nested inside a blockquote" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "blockquote", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Inside blockquote" }] }, { "type" => "licenseKey" }] }])
      expect(rich_content.has_license_key?).to be(true)
    end
  end

  describe "#has_posts?" do
    let(:product) { create(:product) }

    it "returns false if it does not contain posts" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
      expect(rich_content.has_posts?).to be(false)
    end

    it "returns true if it contains posts" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "posts" }])
      expect(rich_content.has_posts?).to be(true)
    end

    it "returns true if it contains posts nested inside a list item" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "orderedList", "content" => [{ "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ordered list item 2" }] }, { "type" => "posts" }] }] }])
      expect(rich_content.has_posts?).to be(true)
    end

    it "returns true if it contains posts nested inside a blockquote" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "blockquote", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Inside blockquote" }] }, { "type" => "posts" }] }])
      expect(rich_content.has_posts?).to be(true)
    end
  end

  describe "#custom_field_nodes" do
    let(:product) { create(:product) }

    let(:paragraph_node) do
      {
        "type" => "paragraph",
        "content" => [{ "type" => "text", "text" => "Item 1" }]
      }
    end
    let(:short_answer_node_1) do
      {
        "type" => "shortAnswer",
        "attrs" => {
          "id" => "short-answer-id",
          "label" => "Short answer field",
        }
      }
    end
    let(:short_answer_node_2) do
      {
        "type" => "shortAnswer",
        "attrs" => {
          "id" => "short-answer-id-2",
          "label" => "Short answer field 2",
        }
      }
    end
    let(:long_answer_node_1) do
      {
        "type" => "longAnswer",
        "attrs" => {
          "id" => "long-answer-id",
          "label" => "Long answer field",
        }
      }
    end
    let(:file_upload_node) do
      {
        "type" => "fileUpload",
        "attrs" => {
          "id" => "file-upload-id",
        }
      }
    end

    it "parses out deeply nested custom field nodes in order" do
      description = [
        {
          "type" => "orderedList",
          "attrs" => { "start" => 1 },
          "content" => [
            {
              "type" => "listItem",
              "content" => [
                paragraph_node,
                short_answer_node_1,
              ]
            },
          ]
        },
        {
          "type" => "bulletList",
          "content" => [
            {
              "type" => "listItem",
              "content" => [
                paragraph_node,
                long_answer_node_1,
              ]
            },
          ]
        },
        {
          "type" => "blockquote",
          "content" => [
            paragraph_node,
            short_answer_node_2,
          ]
        },
        paragraph_node,
        file_upload_node,
      ]
      rich_content = create(:rich_content, entity: product, description:)

      expect(rich_content.custom_field_nodes).to eq(
        [
          short_answer_node_1,
          long_answer_node_1,
          short_answer_node_2,
          file_upload_node,
        ]
      )
    end
  end
end
