# frozen_string_literal: true

require "spec_helper"

describe Purchase::CustomFields do
  let(:purchase) { create(:purchase) }

  describe "validations" do
    it "invalidates the purchase when a custom field is invalid" do
      product = create(:product, custom_fields: [create(:custom_field, name: "http://test", type: "terms", required: true)])
      purchase = build(:purchase, link: product)
      purchase.purchase_custom_fields << PurchaseCustomField.build_from_custom_field(custom_field: product.custom_fields.first, value: false)
      expect(purchase).to be_invalid
      expect(purchase.purchase_custom_fields.first.errors.full_messages).to contain_exactly("Value can't be blank")
      expect(purchase.errors.full_messages).to contain_exactly("Purchase custom fields is invalid")
    end
  end

  describe "#custom_fields" do
    context "when there are custom field records" do
      before do
        purchase.purchase_custom_fields << [
          build(:purchase_custom_field, name: "Text", value: "Value", type: CustomField::TYPE_TEXT),
          build(:purchase_custom_field, name: "Truthy", value: true, type: CustomField::TYPE_CHECKBOX),
          build(:purchase_custom_field, name: "Falsy", value: false, type: CustomField::TYPE_CHECKBOX),
          build(:purchase_custom_field, name: "http://terms", value: true, type: CustomField::TYPE_TERMS)
        ]
      end

      it "returns the custom field records" do
        expect(purchase.custom_fields).to eq(
          [
            { name: "Text", value: "Value", type: CustomField::TYPE_TEXT },
            { name: "Truthy", value: true, type: CustomField::TYPE_CHECKBOX },
            { name: "Falsy", value: false, type: CustomField::TYPE_CHECKBOX },
            { name: "http://terms", value: true, type: CustomField::TYPE_TERMS }
          ]
        )
      end
    end

    context "when there are no custom field records" do
      it "returns an empty array" do
        expect(purchase.custom_fields).to eq([])
      end
    end
  end
end
