# frozen_string_literal: true

require "test_helper"

class UpdateTaxRatesJobTest < ActiveSupport::TestCase
  self.described_class = UpdateTaxRatesJob
  self.rspec_metadata = { vcr: true }



  context_ UpdateTaxRatesJob, :vcr do
  context_ "#perform" do
  test "creates rates for countries if they don't exist" do
        zero_rate_state_codes = ["DE", "MT", "NH", "OR"]

        expect { described_class.new.perform }.to change(ZipTaxRate, :count).from(0).to(Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES.size + Compliance::Countries::TAXABLE_US_STATE_CODES.reject { |taxable_state_code| zero_rate_state_codes.include?(taxable_state_code) }.size + Compliance::Countries::CAN.subdivisions.size)
      end

  test "updates VAT rates for countries if there are any new updates" do
        epublication_zip_tax_rate = create(:zip_tax_rate, country: "AT", combined_rate: 0.10, is_epublication_rate: true)

        described_class.new.perform

        zip_tax_rate = ZipTaxRate.not_is_epublication_rate.find_by(country: "AT")
        zip_tax_rate.update(combined_rate: 0)

        described_class.new.perform

        expect(zip_tax_rate.reload.combined_rate).to eq(0.20)

        # just ensure epublication rates aren't impacted by the periodic job
        expect(epublication_zip_tax_rate.combined_rate).to eq(0.10)
      end

  test "makes sure updated VAT is alive" do
        described_class.new.perform

        ZipTaxRate.last.mark_deleted!

        described_class.new.perform

        expect(ZipTaxRate.last).to be_alive
      end

  test "updates rates for US states if there are any new updates" do
        zip_tax_rate = create(:zip_tax_rate, country: "US", state: "CA", zip_code: nil, combined_rate: 0.01, is_seller_responsible: true)

        described_class.new.perform

        expect(zip_tax_rate.reload.combined_rate).to eq(0.01)
      end

  test "updates rates for Canada provinces if there are any new updates" do
        zip_tax_rate = create(:zip_tax_rate, country: "CA", state: "QC", combined_rate: 0.01)

        described_class.new.perform

        expect(zip_tax_rate.reload.combined_rate).to eq(0.1498)
      end
    end
  end
end
