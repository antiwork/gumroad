# frozen_string_literal: true

describe "#extract_month_and_year" do
  before do
    @expiry_date = "05 / 15"
  end

  describe "valid expiry_date" do
    it "extracts the month and year from a date" do
      expiry_month, expiry_year = CreditCardUtility.extract_month_and_year(@expiry_date)
      expect(expiry_month).to eq "05"
      expect(expiry_year).to eq "15"
    end
  end

  describe "invalid expiry date" do
    before do
      @expiry_date = "05 /"
    end

    it "returns nil" do
      expect(CreditCardUtility.extract_month_and_year(@expiry_date)).to eq [nil, nil]
    end
  end
end
