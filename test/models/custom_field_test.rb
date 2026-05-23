# frozen_string_literal: true

require "test_helper"

class CustomFieldTest < ActiveSupport::TestCase
  self.described_class = CustomField



  context_ CustomField do
  context_ "#as_json" do
  test "returns the correct data" do
        product = create(:product)
        field = create(:custom_field, products: [product])
        expect(field.as_json).to eq({
                                      id: field.external_id,
                                      type: field.type,
                                      name: field.name,
                                      required: field.required,
                                      global: field.global,
                                      collect_per_product: field.collect_per_product,
                                      products: [product.external_id],
                                    })
      end
    end

  context_ "validations" do
  test "validates that the field name is a valid URI for terms fields" do
        field = create(:custom_field, global: true)
        field.update(field_type: "terms")
        expect(field.errors.full_messages).to include("Please provide a valid URL for custom field of Terms type.")
      end

  test "disallows boolean fields for post-purchase custom fields" do
        field = build(:custom_field, is_post_purchase: true, field_type: CustomField::TYPE_CHECKBOX)
        expect(field).not_to be_valid
        expect(field.errors.full_messages).to include("Boolean post-purchase fields are not allowed")

        field.field_type = CustomField::TYPE_TERMS
        expect(field).not_to be_valid
        expect(field.errors.full_messages).to include("Boolean post-purchase fields are not allowed")

        field.field_type = CustomField::TYPE_TEXT
        expect(field).to be_valid
      end
    end

  context_ "defaults" do
  test "sets the default name for file fields" do
        file_field = create(:custom_field, field_type: CustomField::TYPE_FILE, name: nil)
        expect(file_field.name).to eq(CustomField::FILE_FIELD_NAME)
      end

  test "raises an error when name is nil for non-file fields" do
        expect do
          create(:custom_field, field_type: CustomField::TYPE_TEXT, name: nil)
        end.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end
end
