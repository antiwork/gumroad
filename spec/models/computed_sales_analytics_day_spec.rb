# frozen_string_literal: true

require "spec_helper"

RSpec.describe ComputedSalesAnalyticsDay do
  describe ".read_data_from_keys" do
    it "returns hash with sorted existing keys and parsed values" do
      create(:computed_sales_analytics_day, key: "k2", data: { v: 2 }.to_json)
      create(:computed_sales_analytics_day, key: "k0", data: { v: 0 }.to_json)
      result = described_class.read_data_from_keys(["k0", "k1", "k2"])
      expected_result = {
        "k0" => { "v" => 0 },
        "k1" => nil,
        "k2" => { "v" => 2 }
      }
      expect(result.to_a).to eq(expected_result.to_a)
    end
  end

  describe ".fetch_data_from_key" do
    it "creates record if the key does not exist, returns existing  data if it does" do
      expect do
        result = described_class.fetch_data_from_key("k0") { { "v" => 0 } }
        expect(result).to eq({ "v" => 0 })
      end.to change(described_class, :count)
      expect do
        result = described_class.fetch_data_from_key("k0") { { "v" => 1 } }
        expect(result).to eq({ "v" => 0 })
      end.not_to change(described_class, :count)
    end
  end

  describe ".upsert_data_from_key" do
    it "creates a record if it doesn't exist, update data if it does" do
      expect do
        described_class.upsert_data_from_key("k0", { "v" => 0 })
      end.to change(described_class, :count)
      expect(described_class.last.data).to eq({ "v" => 0 }.to_json)
      expect do
        described_class.upsert_data_from_key("k0", { "v" => 1 })
      end.not_to change(described_class, :count)
      expect(described_class.last.data).to eq({ "v" => 1 }.to_json)
    end
  end
end
