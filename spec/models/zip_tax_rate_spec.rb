# frozen_string_literal: true

require "spec_helper"

describe ZipTaxRate do
  it "requires a combined rate" do
    ztr = ZipTaxRate.new(zip_code: "90210", country: "US", state: "CA", is_seller_responsible: true)
    expect(ztr).to_not be_valid
  end

  describe "flags" do
    it "has `is_seller_responsible` flag" do
      flag_on = create(:zip_tax_rate, country: "GB", combined_rate: 0.1, is_seller_responsible: true)
      flag_off = create(:zip_tax_rate, country: "IT", combined_rate: 0.22, is_seller_responsible: false)

      expect(flag_on.is_seller_responsible).to be true
      expect(flag_off.is_seller_responsible).to be false
    end

    it "has `is_epublication_rate` flag" do
      flag_on = create(:zip_tax_rate, country: "AT", combined_rate: 0.1, is_epublication_rate: true)
      flag_off = create(:zip_tax_rate, country: "AT", combined_rate: 0.2, is_epublication_rate: false)

      expect(flag_on.is_epublication_rate).to be true
      expect(flag_off.is_epublication_rate).to be false
    end
  end

  describe "applicable years" do
    it "supports applicable years" do
      ztr = create(:zip_tax_rate, country: "SG", state: nil, zip_code: nil, combined_rate: 0.08, is_seller_responsible: false, applicable_years: [2023])

      expect(ztr.applicable_years).to eq([2023])
    end
  end
end
