# frozen_string_literal: true

require "spec_helper"

describe SalesTaxCalculation do
  it "returns a valid object for the zero tax helper" do
    taxation_info = SalesTaxCalculation.zero_tax(100)

    expect(taxation_info.price_cents).to eq(100)
    expect(taxation_info.tax_cents).to eq(0)
    expect(taxation_info.zip_tax_rate).to be(nil)
  end

  describe "to_hash" do
    it "returns a valid hash even on zero/no/invalid tax calculation" do
      actual_hash = SalesTaxCalculation.zero_tax(100).to_hash

      expect(actual_hash[:price_cents]).to eq(100)
      expect(actual_hash[:tax_cents]).to eq(0)
      expect(actual_hash[:has_vat_id_input]).to eq(false)
    end

    it "serializes a valid tax calculation" do
      zip_tax_rate = create(:zip_tax_rate, is_seller_responsible: 0)
      actual_hash = SalesTaxCalculation.new(price_cents: 100,
                                            tax_cents: 10,
                                            zip_tax_rate:).to_hash

      expect(actual_hash[:price_cents]).to eq(100)
      expect(actual_hash[:tax_cents]).to eq(10)
      expect(actual_hash[:has_vat_id_input]).to be(false)
    end

    it "serializes a valid tax calculation for an EU country" do
      zip_tax_rate = create(:zip_tax_rate, country: "IT", is_seller_responsible: 0)
      actual_hash = SalesTaxCalculation.new(price_cents: 100,
                                            tax_cents: 10,
                                            zip_tax_rate:).to_hash

      expect(actual_hash[:price_cents]).to eq(100)
      expect(actual_hash[:tax_cents]).to eq(10)
      expect(actual_hash[:has_vat_id_input]).to be(true)
    end

    it "serializes a valid tax calculation for Australia" do
      zip_tax_rate = create(:zip_tax_rate, country: "AU", is_seller_responsible: 0)
      actual_hash = SalesTaxCalculation.new(price_cents: 100,
                                            tax_cents: 10,
                                            zip_tax_rate:).to_hash

      expect(actual_hash[:price_cents]).to eq(100)
      expect(actual_hash[:tax_cents]).to eq(10)
      expect(actual_hash[:has_vat_id_input]).to be(true)
    end

    it "serializes a valid tax calculation for Singapore" do
      zip_tax_rate = create(:zip_tax_rate, country: "SG", is_seller_responsible: 0)
      actual_hash = SalesTaxCalculation.new(price_cents: 100,
                                            tax_cents: 8,
                                            zip_tax_rate:).to_hash

      expect(actual_hash[:price_cents]).to eq(100)
      expect(actual_hash[:tax_cents]).to eq(8)
      expect(actual_hash[:has_vat_id_input]).to be(true)
    end

    it "serializes a valid tax calculation for Canada province Quebec" do
      actual_hash = SalesTaxCalculation.new(price_cents: 100,
                                            tax_cents: 8,
                                            zip_tax_rate: nil,
                                            is_quebec: true).to_hash

      expect(actual_hash[:price_cents]).to eq(100)
      expect(actual_hash[:tax_cents]).to eq(8)
      expect(actual_hash[:has_vat_id_input]).to be(true)
    end
  end
end
