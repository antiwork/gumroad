# frozen_string_literal: true

require "spec_helper"

describe StripeTaxFormsApi, vcr: { cassette_name: "StripeTaxFormsApi/tax_forms" } do
  let(:stripe_account_id) { "acct_1234567890" }
  let(:form_type) { "us_1099_k" }
  let(:year) { 2024 }
  let(:service) { described_class.new(stripe_account_id:, form_type:, year:) }

  describe "#tax_forms_by_year" do
    it "returns tax forms grouped by year" do
      result = service.tax_forms_by_year

      expect(result.keys).to eq([2024, 2023, 2022, 2021, 2020])

      tax_form_2024 = result[2024]
      expect(tax_form_2024.id).to eq("taxform_1")
      expect(tax_form_2024.object).to eq("tax.form")
      expect(tax_form_2024.type).to eq("us_1099_k")
      expect(tax_form_2024.livemode).to be(true)
      expect(tax_form_2024.payee.account).to eq("acct_1234567890")
      expect(tax_form_2024.us_1099_k.reporting_year).to eq(2024)
    end

    it "raises error for invalid form type" do
      invalid_service = described_class.new(stripe_account_id:, form_type: "invalid_type", year:)

      expect { invalid_service.tax_forms_by_year }.to raise_error(RuntimeError, "Invalid tax form type: invalid_type")
    end

    it "returns empty hash on Stripe API error" do
      allow(Stripe).to receive(:raw_request).and_raise(Stripe::APIConnectionError.new("Connection failed"))
      expect(Bugsnag).to receive(:notify).with(instance_of(Stripe::APIConnectionError))

      result = service.tax_forms_by_year

      expect(result).to eq({})
    end
  end

  describe "#download_tax_form" do
    it "downloads the tax form PDF for the specified year" do
      allow(HTTParty).to receive(:get).and_yield("PDF content")

      result = service.download_tax_form

      expect(result).to be_a(Tempfile)
      expect(result.path).to include("tax_form_us_1099_k_2024_acct_1234567890")
      expect(result.path).to end_with(".pdf")
      expect(HTTParty).to have_received(:get).with(
        "https://files.stripe.com/v1/tax/forms/taxform_1/pdf",
        hash_including(headers: hash_including("Authorization" => /Bearer/))
      )
      result.close
      result.unlink
    end

    it "returns nil when tax form not found for the year" do
      service_2019 = described_class.new(stripe_account_id:, form_type:, year: 2019)

      result = service_2019.download_tax_form

      expect(result).to be_nil
    end

    it "returns nil when there is an error" do
      allow(HTTParty).to receive(:get).and_raise(HTTParty::Error.new("Connection failed"))
      expect(Bugsnag).to receive(:notify).with(instance_of(HTTParty::Error))

      result = service.download_tax_form

      expect(result).to be_nil
    end
  end
end
