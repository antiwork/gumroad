# frozen_string_literal: true

require "test_helper"

class SellerProfileProductsSectionTest < ActiveSupport::TestCase
  self.described_class = SellerProfileProductsSection



  context_ SellerProfileProductsSection do
  context_ "validations" do
  test "validates json_data with the correct schema" do
        section = build(:seller_profile_products_section, shown_products: [create(:product, name: "Product 1").id])
        section.json_data["garbage"] = "should not be here"
        schema = JSON.parse(File.read(Rails.root.join("lib", "json_schemas", "seller_profile_products_section.json").to_s))
        expect(JSON::Validator).to receive(:new).with(schema, insert_defaults: true, record_errors: true).and_wrap_original do |original, *args|
          validator = original.call(*args)
          expect(validator).to receive(:validate).with(section.json_data).and_call_original
          validator
        end
        section.validate
        expect(section.errors.full_messages.to_sentence).to eq("The property '#/' contains additional properties [\"garbage\"] outside of the schema when none are allowed")
      end
    end

  context_ "#product_names" do
      let(:seller) { create(:user) }
      let(:section) { create(:seller_profile_products_section, seller:, shown_products: [create(:product, user: seller, name: "Product 1").id, create(:product, user: seller, name: "Product 2").id]) }

  test "returns the names of the products in the section" do
        expect(section.product_names).to eq(["Product 1", "Product 2"])
      end
    end
  end
end
