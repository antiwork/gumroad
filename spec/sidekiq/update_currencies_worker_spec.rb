# frozen_string_literal: true

require "spec_helper"

describe UpdateCurrenciesWorker, :vcr do
  describe "#perform" do
    before do
      @worker_instance = described_class.new
    end

    it "updates currencies for current date" do
      @worker_instance.currency_namespace.set("AUD", "0.1111")
      expect(@worker_instance.get_rate("AUD")).to eq("0.1111")

      @worker_instance.perform

      # In test this is a fixed rate read from a file
      expect(@worker_instance.get_rate("AUD")).to eq("0.969509")
    end
  end
end
