# frozen_string_literal: true

require "spec_helper"

describe BillingDetail do
  let(:user) { create(:user) }

  describe "validations" do
    it "requires full_name, street_address, city, zip_code, country_code" do
      billing_detail = described_class.new(purchaser: user)
      expect(billing_detail).not_to be_valid
      %i[full_name street_address city zip_code country_code].each do |attr|
        expect(billing_detail.errors[attr]).to include("can't be blank")
      end
    end

    it "requires state when country is US" do
      billing_detail = described_class.new(
        purchaser: user,
        full_name: "Alice",
        street_address: "1 Market",
        city: "San Francisco",
        zip_code: "94107",
        country_code: "US"
      )
      expect(billing_detail).not_to be_valid
      expect(billing_detail.errors[:state]).to include("can't be blank")
    end

    it "does not require state when country is not US" do
      billing_detail = described_class.new(
        purchaser: user,
        full_name: "Alice",
        street_address: "1 Unter den Linden",
        city: "Berlin",
        zip_code: "10115",
        country_code: "DE"
      )
      expect(billing_detail).to be_valid
    end

    it "validates country_code is a two-letter code" do
      billing_detail = build(:billing_detail, purchaser: user, country_code: "DEU")
      expect(billing_detail).not_to be_valid
      expect(billing_detail.errors[:country_code]).to include("is the wrong length (should be 2 characters)")
    end

    it "enforces one billing detail per purchaser" do
      create(:billing_detail, purchaser: user)
      duplicate = build(:billing_detail, purchaser: user)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:purchaser_id]).to include("has already been taken")
    end
  end

  describe "#to_invoice_address_fields" do
    it "returns the address fields formatted for the invoice presenter" do
      billing_detail = build(:billing_detail, :us, purchaser: user)
      expect(billing_detail.to_invoice_address_fields).to eq(
        full_name: "John Doe",
        street_address: "123 Main Street",
        city: "San Francisco",
        state: "CA",
        zip_code: "94107",
        country_code: "US",
      )
    end
  end

  describe "defaults" do
    it "defaults auto_email_invoice_enabled to true" do
      billing_detail = described_class.new
      expect(billing_detail.auto_email_invoice_enabled).to eq(true)
    end
  end

  describe "User#billing_detail" do
    it "is destroyed when the user is destroyed" do
      create(:billing_detail, purchaser: user)
      expect { user.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
