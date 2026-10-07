# frozen_string_literal: true

require "spec_helper"
require "timeout"

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

    it "returns the winning value when another writer fills the key during computation" do
      result = described_class.fetch_data_from_key("racing-key") do
        described_class.fetch_data_from_key("racing-key") { { "winner" => true } }
        { "winner" => false }
      end

      expect(result).to eq("winner" => true)
      expect(described_class.where(key: "racing-key").count).to eq(1)
    end

    it "does not compute or rewrite an existing cache entry" do
      record = create(:computed_sales_analytics_day, key: "existing-key", data: { v: 1 }.to_json, created_at: 2.days.ago, updated_at: 1.day.ago)
      original_attributes = record.attributes

      expect(described_class.fetch_data_from_key(record.key) { raise "cache hit computed" }).to eq("v" => 1)
      expect(record.reload.attributes).to eq(original_attributes)
    end

    it "does not persist a key when computation fails" do
      expect do
        described_class.fetch_data_from_key("failed-key") { raise "computation failed" }
      end.to raise_error("computation failed")

      expect(described_class.exists?(key: "failed-key")).to be(false)
    end

    it "computes before opening any additional database transaction" do
      transaction_depth = described_class.connection.open_transactions

      described_class.fetch_data_from_key("computed-key") do
        expect(described_class.connection.open_transactions).to eq(transaction_depth)
        { v: 1 }
      end
    end

    it "does not hide invalid JSON in an existing entry" do
      create(:computed_sales_analytics_day, key: "invalid-key", data: "{")

      expect do
        described_class.fetch_data_from_key("invalid-key") { raise "cache hit computed" }
      end.to raise_error(JSON::ParserError)
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

    it "returns the existing record and preserves its creation time when replacing data" do
      record = create(:computed_sales_analytics_day, key: "existing-key", data: { v: 1 }.to_json, created_at: 2.days.ago, updated_at: 1.day.ago)
      original_created_at = record.created_at
      original_updated_at = record.updated_at

      result = described_class.upsert_data_from_key(record.key, { v: 2 })

      expect(result).to be_a(described_class)
      expect(result.id).to eq(record.id)
      expect(result.reload.data).to eq({ v: 2 }.to_json)
      expect(result.created_at).to eq(original_created_at)
      expect(result.updated_at).to be > original_updated_at
    end

    context "with concurrent first writers" do
      self.use_transactional_tests = false

      it "replaces one unique cache entry without failing either writer" do
        key = "concurrent-#{SecureRandom.hex(8)}"
        arrived = Queue.new
        release = Queue.new
        threads = []
        subscriber = Object.new
        subscriber.define_singleton_method(:start) do |*, payload|
          next unless Thread.current[:computed_day_first_write] && payload[:sql].start_with?("INSERT INTO `computed_sales_analytics_days`")

          Thread.current[:computed_day_first_write] = false
          arrived << true
          release.pop
        end
        subscriber.define_singleton_method(:finish) { |*| }

        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
          threads = [1, 2].map do |value|
            Thread.new do
              Thread.current[:computed_day_first_write] = true
              described_class.connection_pool.with_connection do
                described_class.upsert_data_from_key(key, { v: value })
              end
            rescue StandardError => error
              error
            end
          end
          Timeout.timeout(10) { 2.times { arrived.pop } }
          2.times { release << true }
          results = threads.map { |thread| Timeout.timeout(10) { thread.value } }

          results.each do |result|
            raise result if result.is_a?(StandardError)
            expect(result).to be_a(described_class)
          end
          expect(described_class.where(key:).count).to eq(1)
          expect(JSON.parse(described_class.find_by!(key:).data)).to satisfy { |data| [1, 2].include?(data.fetch("v")) }
        end
      ensure
        2.times { release << true }
        threads.each { |thread| thread.join(2) || thread.kill }
        described_class.where(key:).delete_all
      end
    end
  end
end
