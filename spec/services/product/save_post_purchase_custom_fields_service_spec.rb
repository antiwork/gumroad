# frozen_string_literal: true

require "spec_helper"

describe Product::SavePostPurchaseCustomFieldsService do
  describe "#perform" do
    let(:product) { create(:product_with_digital_versions, has_same_rich_content_for_all_variants: true) }

    let!(:long_answer) { create(:custom_field, seller: product.user, products: [product], field_type: CustomField::TYPE_LONG_TEXT, is_post_purchase: true) }
    let!(:short_answer) { create(:custom_field, seller: product.user, products: [product], field_type: CustomField::TYPE_TEXT, is_post_purchase: true) }
    let!(:non_post_purchase) { create(:custom_field, seller: product.user, products: [product], field_type: CustomField::TYPE_TEXT) }
    let!(:rich_content) do
      create(
        :product_rich_content,
        entity: product,
        description: [
          {
            "type" => RichContent::LONG_ANSWER_NODE_TYPE,
            "attrs" => {
              "id" => long_answer.external_id,
              "label" => "Long answer"
            }
          },
          {
            "type" => RichContent::FILE_UPLOAD_NODE_TYPE,
          },
          {
            "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
            "attrs" => {
              "label" => "New short answer"
            },
          },
          {
            "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
            "attrs" => {
              "id" => non_post_purchase.external_id,
              "label" => "Non post purchase short answer"
            },
          }
        ]
      )
    end

    it "syncs post-purchase custom fields with rich content nodes" do
      expect do
        described_class.new(product.reload).perform
      end.to change { CustomField.exists?(short_answer.id) }.from(true).to(false)
        .and change { long_answer.reload.name }.from("Custom field").to("Long answer")
        .and not_change { non_post_purchase.reload.name }

      file_upload = product.custom_fields.find_by(field_type: CustomField::TYPE_FILE)
      expect(file_upload.seller).to eq(product.user)
      expect(file_upload.products).to eq([product])
      expect(file_upload.is_post_purchase).to eq(true)

      new_short_answer = product.custom_fields.where(field_type: CustomField::TYPE_TEXT).second_to_last
      expect(new_short_answer.seller).to eq(product.user)
      expect(new_short_answer.products).to eq([product])
      expect(new_short_answer.name).to eq("New short answer")
      expect(new_short_answer.is_post_purchase).to eq(true)

      other_new_short_answer = product.custom_fields.where(field_type: CustomField::TYPE_TEXT).last
      expect(other_new_short_answer.seller).to eq(product.user)
      expect(other_new_short_answer.products).to eq([product])
      expect(other_new_short_answer.name).to eq("Non post purchase short answer")
      expect(other_new_short_answer.is_post_purchase).to eq(true)

      expect(rich_content.reload.description).to eq(
        [
          {
            "type" => RichContent::LONG_ANSWER_NODE_TYPE,
            "attrs" => {
              "id" => long_answer.external_id,
              "label" => "Long answer"
            }
          },
          {
            "type" => RichContent::FILE_UPLOAD_NODE_TYPE,
            "attrs" => { "id" => file_upload.external_id }
          },
          {
            "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
            "attrs" => {
              "label" => "New short answer",
              "id" => new_short_answer.external_id,
            },
          },
          {
            "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
            "attrs" => {
              "id" => other_new_short_answer.external_id,
              "label" => "Non post purchase short answer"
            },
          }
        ]
      )
    end

    context "product has different content for each variant" do
      let!(:rich_content1) do
        create(
          :rich_content,
          entity: product.alive_variants.first,
          description: [
            {
              "type" => RichContent::LONG_ANSWER_NODE_TYPE,
              "attrs" => {
                "id" => long_answer.external_id,
                "label" => "Long answer 1"
              }
            },
            {
              "type" => RichContent::FILE_UPLOAD_NODE_TYPE,
            },
            {
              "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
              "attrs" => {
                "label" => "New short answer 1"
              },
            },
            {
              "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
              "attrs" => {
                "id" => non_post_purchase.external_id,
                "label" => "Non post purchase short answer 1"
              },
            }
          ]
        )
      end

      let!(:rich_content2) do
        create(
          :rich_content,
          entity: product.alive_variants.second,
          description: [
            {
              "type" => RichContent::FILE_UPLOAD_NODE_TYPE,
            },
            {
              "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
              "attrs" => {
                "label" => "New short answer 2"
              },
            },
            {
              "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
              "attrs" => {
                "id" => non_post_purchase.external_id,
                "label" => "Non post purchase short answer 2"
              },
            }
          ]
        )
      end

      before { product.update!(has_same_rich_content_for_all_variants: false) }

      it "syncs post-purchase custom fields with rich content nodes for all variants" do
        expect do
          described_class.new(product.reload).perform
        end.to change { CustomField.exists?(short_answer.id) }.from(true).to(false)
          .and change { long_answer.reload.name }.from("Custom field").to("Long answer 1")
          .and not_change { non_post_purchase.reload.name }

        file_upload1 = product.custom_fields.where(field_type: CustomField::TYPE_FILE).first
        expect(file_upload1.seller).to eq(product.user)
        expect(file_upload1.products).to eq([product])
        expect(file_upload1.is_post_purchase).to eq(true)

        new_short_answer1 = product.custom_fields.where(field_type: CustomField::TYPE_TEXT).find_by(name: "New short answer 1")
        expect(new_short_answer1.seller).to eq(product.user)
        expect(new_short_answer1.products).to eq([product])
        expect(new_short_answer1.is_post_purchase).to eq(true)

        other_new_short_answer1 = product.custom_fields.where(field_type: CustomField::TYPE_TEXT).find_by(name: "Non post purchase short answer 1")
        expect(other_new_short_answer1.seller).to eq(product.user)
        expect(other_new_short_answer1.products).to eq([product])
        expect(other_new_short_answer1.is_post_purchase).to eq(true)

        expect(rich_content1.reload.description).to eq(
          [
            {
              "type" => RichContent::LONG_ANSWER_NODE_TYPE,
              "attrs" => {
                "id" => long_answer.external_id,
                "label" => "Long answer 1"
              }
            },
            {
              "type" => RichContent::FILE_UPLOAD_NODE_TYPE,
              "attrs" => { "id" => file_upload1.external_id }
            },
            {
              "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
              "attrs" => {
                "label" => "New short answer 1",
                "id" => new_short_answer1.external_id,
              },
            },
            {
              "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
              "attrs" => {
                "id" => other_new_short_answer1.external_id,
                "label" => "Non post purchase short answer 1"
              },
            }
          ]
        )

        file_upload2 = product.custom_fields.where(field_type: CustomField::TYPE_FILE).second
        expect(file_upload2.seller).to eq(product.user)
        expect(file_upload2.products).to eq([product])
        expect(file_upload2.is_post_purchase).to eq(true)

        new_short_answer2 = product.custom_fields.where(field_type: CustomField::TYPE_TEXT).find_by(name: "New short answer 2")
        expect(new_short_answer2.seller).to eq(product.user)
        expect(new_short_answer2.products).to eq([product])
        expect(new_short_answer2.is_post_purchase).to eq(true)

        other_new_short_answer2 = product.custom_fields.where(field_type: CustomField::TYPE_TEXT).find_by(name: "Non post purchase short answer 2")
        expect(other_new_short_answer2.seller).to eq(product.user)
        expect(other_new_short_answer2.products).to eq([product])
        expect(other_new_short_answer2.is_post_purchase).to eq(true)

        expect(rich_content2.reload.description).to eq(
          [
            {
              "type" => RichContent::FILE_UPLOAD_NODE_TYPE,
              "attrs" => { "id" => file_upload2.external_id }
            },
            {
              "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
              "attrs" => {
                "label" => "New short answer 2",
                "id" => new_short_answer2.external_id,
              },
            },
            {
              "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
              "attrs" => {
                "id" => other_new_short_answer2.external_id,
                "label" => "Non post purchase short answer 2"
              },
            }
          ]
        )
      end
    end
  end
end
