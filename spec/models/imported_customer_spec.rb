# frozen_string_literal: true

require "spec_helper"

describe ImportedCustomer do
  describe "validations" do
    it "requires an email to create an ImportedCustomer" do
      imported_customer_invalid = ImportedCustomer.new(email: nil)
      expect(imported_customer_invalid).to_not be_valid
      valid_customer = ImportedCustomer.new(email: "me@maxwell.com")
      expect(valid_customer).to be_valid
    end
  end

  describe "as_json" do
    it "includes imported customer details" do
      imported_customer = create(:imported_customer, link: create(:product))

      result = imported_customer.as_json

      expect(result["email"]).to be_present
      expect(result["created_at"]).to be_present
      expect(result[:link_name]).to be_present
      expect(result[:product_name]).to be_present
      expect(result[:price]).to be_nil
      expect(result[:is_imported_customer]).to be true
      expect(result[:purchase_email]).to be_present
      expect(result[:id]).to be_present
    end
  end
end
