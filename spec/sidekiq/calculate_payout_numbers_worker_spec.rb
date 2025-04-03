# frozen_string_literal: true

require "spec_helper"

describe CalculatePayoutNumbersWorker, :sidekiq_inline, :elasticsearch_wait_for_refresh do
  describe "#perform" do
    before { recreate_model_indices(Purchase) }

    context "when purchases are present" do
      let(:now) { Time.now.in_time_zone("America/Los_Angeles") }
      let(:beginning_of_last_week) { now.prev_week }
      let(:end_of_last_week) { beginning_of_last_week.end_of_week }

      before do
        travel_to(beginning_of_last_week + 30.minutes) do
          create(:purchase, price_cents: 123_45)
          create(:purchase, price_cents: 234_56)
          create(:purchase, price_cents: 567_89)
          create(:purchase, price_cents: 0)
          create(:purchase, price_cents: 890_12)
          create(:purchase, price_cents: 1890_12, chargeback_date: Date.today)
          create(:refunded_purchase, price_cents: 1890_12)
          create(:failed_purchase, price_cents: 111_890_12)
        end

        travel_to(beginning_of_last_week - 1.second) do
          create_list(:purchase, 5, price_cents: 99_999_00)
        end

        travel_to(end_of_last_week + 1.second) do
          create_list(:purchase, 5, price_cents: 99_999_00)
        end
      end

      let(:expected_total) { (123_45 + 234_56 + 567_89 + 890_12) / 100.0 }

      it "stores the expected payout data in Redis" do
        described_class.new.perform

        expect($redis.get(RedisKey.prev_week_payout_usd)).to eq(expected_total.to_i.to_s)
      end
    end

    context "when there is no data" do
      it "stores zero in Redis" do
        described_class.new.perform

        expect($redis.get(RedisKey.prev_week_payout_usd)).to eq("0")
      end
    end
  end
end
