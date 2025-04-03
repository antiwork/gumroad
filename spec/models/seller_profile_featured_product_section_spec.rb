# frozen_string_literal: true

require "spec_helper"

describe SellerProfileFeaturedProductSection do
  describe "validations" do
    it "validates json_data with the correct schema" do
      section = build(:seller_profile_featured_product_section, featured_product_id: 1)
      section.json_data["garbage"] = "should not be here"
      schema = JSON.parse(File.read(Rails.root.join("lib", "json_schemas", "seller_profile_featured_product_section.json").to_s))
      expect(JSON::Validator).to receive(:new).with(schema, insert_defaults: true, record_errors: true).and_wrap_original do |original, *args|
        validator = original.call(*args)
        expect(validator).to receive(:validate).with(section.json_data).and_call_original
        validator
      end
      section.validate
      expect(section.errors.full_messages.to_sentence).to eq("The property '#/' contains additional properties [\"garbage\"] outside of the schema when none are allowed")
    end
  end
end
