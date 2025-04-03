# frozen_string_literal: true

require "spec_helper"

describe CustomField do
  describe "#as_json" do
    it "returns the correct data" do
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

  describe "validations" do
    it "validates that the field name is a valid URI for terms fields" do
      field = create(:custom_field, global: true)
      field.update(field_type: "terms")
      expect(field.errors.full_messages).to include("Please provide a valid URL for custom field of Terms type.")
    end

    it "disallows boolean fields for post-purchase custom fields" do
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

  describe "defaults" do
    it "sets the default name for file fields" do
      file_field = create(:custom_field, field_type: CustomField::TYPE_FILE, name: nil)
      expect(file_field.name).to eq(CustomField::FILE_FIELD_NAME)
    end

    it "raises an error when name is nil for non-file fields" do
      expect do
        create(:custom_field, field_type: CustomField::TYPE_TEXT, name: nil)
      end.to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
