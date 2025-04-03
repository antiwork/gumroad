# frozen_string_literal: true

require "spec_helper"

describe PurchaseCustomField do
  describe "validations" do
    it "validates field type is a custom field type" do
      purchase_custom_field = described_class.new(field_type: "invalid")
      expect(purchase_custom_field).not_to be_valid
      expect(purchase_custom_field.errors.full_messages).to include("Field type is not included in the list")
    end

    it "validates name is present" do
      purchase_custom_field = described_class.new
      expect(purchase_custom_field).not_to be_valid
      expect(purchase_custom_field.errors.full_messages).to include("Name can't be blank")
    end
  end

  describe "normalization" do
    it "normalizes value" do
      purchase_custom_field = described_class.new(value: "  test    value  ")
      expect(purchase_custom_field.value).to eq("test value")
    end

    it "converts nil to false for boolean fields" do
      putchase_custom_field = described_class.create(field_type: CustomField::TYPE_CHECKBOX, value: nil)
      expect(putchase_custom_field.value).to eq(false)
    end
  end

  describe "#value_valid_for_custom_field" do
    let(:custom_field) { create(:custom_field) }
    let(:purchase) { create(:purchase) }

    [CustomField::TYPE_TEXT, CustomField::TYPE_LONG_TEXT].each do |type|
      it "requires value for #{type} custom field if required is true" do
        custom_field.update!(type:, required: true)
        purchase_custom_field = described_class.build_from_custom_field(custom_field:, value: "")
        purchase.purchase_custom_fields << purchase_custom_field
        expect(purchase_custom_field).not_to be_valid
        expect(purchase_custom_field.errors.full_messages).to include("Value can't be blank")

        purchase_custom_field.value = "value"
        expect(purchase_custom_field).to be_valid
      end

      it "allows blank for an optional #{type} custom field" do
        custom_field.update!(type:, required: false)
        purchase_custom_field = described_class.build_from_custom_field(custom_field:, value: "")
        purchase.purchase_custom_fields << purchase_custom_field
        expect(purchase_custom_field).to be_valid
      end
    end

    it "requires value for checkbox custom field if required is true" do
      custom_field.update!(type: CustomField::TYPE_CHECKBOX, required: true)
      purchase_custom_field = described_class.build_from_custom_field(custom_field:, value: false)
      purchase.purchase_custom_fields << purchase_custom_field
      expect(purchase_custom_field).not_to be_valid
      expect(purchase_custom_field.errors.full_messages).to include("Value can't be blank")

      purchase_custom_field.value = true
      expect(purchase_custom_field).to be_valid
    end

    it "allows false for an optional checkbox custom field" do
      custom_field.update!(type: CustomField::TYPE_CHECKBOX, required: false)
      purchase_custom_field = described_class.build_from_custom_field(custom_field:, value: false)
      purchase.purchase_custom_fields << purchase_custom_field
      expect(purchase_custom_field).to be_valid
    end

    it "requires value for terms custom field to be true" do
      custom_field.update!(name: "https://test", type: CustomField::TYPE_TERMS, required: true)
      purchase_custom_field = described_class.build_from_custom_field(custom_field:, value: false)
      purchase.purchase_custom_fields << purchase_custom_field
      expect(purchase_custom_field).not_to be_valid
      expect(purchase_custom_field.errors.full_messages).to include("Value can't be blank")

      purchase_custom_field.value = true
      expect(purchase_custom_field).to be_valid
    end

    it "requires file for file custom field if required is true" do
      custom_field.update!(type: CustomField::TYPE_FILE, required: true)
      purchase_custom_field = described_class.build_from_custom_field(custom_field:, value: nil)
      purchase.purchase_custom_fields << purchase_custom_field
      expect(purchase_custom_field).not_to be_valid
      expect(purchase_custom_field.errors.full_messages).to include("Value can't be blank")

      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
      purchase_custom_field.files.attach(blob)
      expect(purchase_custom_field).to be_valid
    end

    it "allows blank for an optional file custom field" do
      custom_field.update!(type: CustomField::TYPE_FILE, required: false)
      purchase_custom_field = described_class.build_from_custom_field(custom_field:, value: nil)
      purchase.purchase_custom_fields << purchase_custom_field
      expect(purchase_custom_field).to be_valid
    end

    it "requires value for file custom field to be nil" do
      custom_field.update!(type: CustomField::TYPE_FILE, required: true)
      purchase_custom_field = described_class.build_from_custom_field(custom_field:, value: "value")
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
      purchase_custom_field.files.attach(blob)
      purchase.purchase_custom_fields << purchase_custom_field
      expect(purchase_custom_field).not_to be_valid
      expect(purchase_custom_field.errors.full_messages).to include("Value cannot be set for file custom field")

      purchase_custom_field.value = nil
      expect(purchase_custom_field).to be_valid
    end
  end

  describe ".build_from_custom_field" do
    it "assigns attributes correctly" do
      custom_field = create(:custom_field)
      purchase_custom_field = described_class.build_from_custom_field(custom_field:, value: "test")
      expect(purchase_custom_field).to have_attributes(
        custom_field:,
        name: custom_field.name,
        field_type: custom_field.type,
        value: "test"
      )
    end
  end

  describe "#value" do
    it "returns the value cast to boolean if the field type is a boolean type" do
      purchase_custom_field = described_class.new(field_type: CustomField::TYPE_CHECKBOX, value: "false")
      expect(purchase_custom_field.value).to eq(false)

      purchase_custom_field = described_class.new(field_type: CustomField::TYPE_TERMS, value: "yes")
      expect(purchase_custom_field.value).to eq(true)
    end

    it "returns the value as is if the field type is not a boolean type" do
      purchase_custom_field = described_class.new(field_type: CustomField::TYPE_TEXT, value: "value")
      expect(purchase_custom_field.value).to eq("value")
    end
  end
end
