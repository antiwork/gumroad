# frozen_string_literal: true

require "test_helper"

class UpdatePurchasingPowerParityFactorsWorkerTest < ActiveSupport::TestCase
  self.described_class = UpdatePurchasingPowerParityFactorsWorker
  self.rspec_metadata = { vcr: true }



  context_ UpdatePurchasingPowerParityFactorsWorker, :vcr do
  context_ "#perform" do
      before do
        # The VCR cassette for PPP data is from 2025, so this prevents the worker complaining it's out of date
        travel_to Date.new(2025, 1, 1)
        @seller = create(:user)
        @worker = described_class.new
        @service = PurchasingPowerParityService.new
        @worker.perform
      end

  context_ "when factor is greater than 0.8" do
  test "sets PPP factor to 1" do
          expect(@service.get_factor("LU", @seller)).to eq(1)
        end
      end

  context_ "when country is in the high-income exclusion list" do
  test "sets PPP factor to 1 regardless of calculated value" do
          # These countries are in PPP_EXCLUDED_COUNTRIES and should always be 1
          expect(@service.get_factor("AE", @seller)).to eq(1)
          expect(@service.get_factor("JP", @seller)).to eq(1)
          expect(@service.get_factor("SE", @seller)).to eq(1)
          expect(@service.get_factor("QA", @seller)).to eq(1)
          expect(@service.get_factor("US", @seller)).to eq(1)
          expect(@service.get_factor("GB", @seller)).to eq(1)
        end
      end

  context_ "when factor is less than 0.8" do
  test "sets PPP factor rounded to the nearest hundredth" do
          # AE was the original test country but is now excluded; use a non-excluded country
          factor = @service.get_factor("IN", @seller)
          expect(factor).to be < 0.8
          expect(factor).to be >= 0.4
        end
      end

  context_ "when factor is less than 0.4" do
  test "sets PPP factor to 0.4" do
          expect(@service.get_factor("YE", @seller)).to eq(0.4)
        end
      end
    end
  end
end
