# frozen_string_literal: true

require "test_helper"

class UpdateCurrenciesWorkerTest < ActiveSupport::TestCase
  self.described_class = UpdateCurrenciesWorker
  self.rspec_metadata = { vcr: true }



  context_ UpdateCurrenciesWorker, :vcr do
  context_ "#perform" do
      before do
        @worker_instance = described_class.new
      end

  test "updates currencies for current date" do
        @worker_instance.currency_namespace.set("AUD", "0.1111")
        expect(@worker_instance.get_rate("AUD")).to eq("0.1111")

        @worker_instance.perform

        # In test this is a fixed rate read from a file
        expect(@worker_instance.get_rate("AUD")).to eq("0.969509")
      end
    end
  end
end
