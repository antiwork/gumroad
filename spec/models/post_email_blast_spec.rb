# frozen_string_literal: true

require "spec_helper"

RSpec.describe PostEmailBlast do
  let(:blast) { create(:post_email_blast) }

  describe ".aggregated", :freeze_time do
    before do
      create(:post_email_blast, requested_at: Time.current, started_at: nil, first_email_delivered_at: nil, last_email_delivered_at: nil, delivery_count: 0)
      create(:post_email_blast, requested_at: 1.day.ago, started_at: 1.day.ago + 30.seconds, first_email_delivered_at: 1.day.ago + 10.minutes, last_email_delivered_at: 1.day.ago + 20.minutes, delivery_count: 15)
      create(:post_email_blast, requested_at: 1.day.ago, started_at: 1.day.ago + 10.seconds, first_email_delivered_at: 1.day.ago + 20.minutes, last_email_delivered_at: 1.day.ago + 40.minutes, delivery_count: 25)
    end

    it "returns the aggregated data" do
      result = PostEmailBlast.aggregated.to_a

      expect(result.size).to eq(2)

      expect(result[0]).to have_attributes(
        date: Date.current,
        total: 1,
        total_delivery_count: 0,
        average_start_latency: nil,
        average_first_email_delivery_latency: nil,
        average_last_email_delivery_latency: nil,
        average_deliveries_per_minute: nil
      )

      expect(result[1]).to have_attributes(
        date: 1.day.ago.to_date,
        total: 2,
        total_delivery_count: 40, # 15 + 25
        average_start_latency: 20.0, # (30 seconds + 10 seconds) / 2
        average_first_email_delivery_latency: 15.minutes.to_f, # (10 minutes + 20 minutes) / 2
        average_last_email_delivery_latency: 30.minutes.to_f, # (20 minutes + 40 minutes) / 2
        average_deliveries_per_minute: 1.375 # (15 deliveries in 10 minutes + 25 deliveries in 20 minutes) / 2
      )
    end
  end

  describe "Latency metrics", :freeze_time do
    describe "#start_latency" do
      it "returns the difference between requested_at and started_at" do
        expect(blast.start_latency).to eq(5.minutes)
      end

      it "returns nil if started_at is nil" do
        blast.update!(started_at: nil)
        expect(blast.start_latency).to be_nil
      end

      it "returns nil if requested_at is nil" do
        blast.update!(requested_at: nil)
        expect(blast.start_latency).to be_nil
      end
    end

    describe "#first_email_delivery_latency" do
      it "returns the difference between requested_at and first_email_delivered_at" do
        expect(blast.first_email_delivery_latency).to eq(10.minutes)
      end

      it "returns nil if first_email_delivered_at is nil" do
        blast.update!(first_email_delivered_at: nil)
        expect(blast.first_email_delivery_latency).to be_nil
      end

      it "returns nil if requested_at is nil" do
        blast.update!(requested_at: nil)
        expect(blast.first_email_delivery_latency).to be_nil
      end
    end

    describe "#last_email_delivery_latency" do
      it "returns the difference between requested_at and last_email_delivered_at" do
        expect(blast.last_email_delivery_latency).to eq(20.minutes)
      end

      it "returns nil if last_email_delivered_at is nil" do
        blast.update!(last_email_delivered_at: nil)
        expect(blast.last_email_delivery_latency).to be_nil
      end

      it "returns nil if requested_at is nil" do
        blast.update!(requested_at: nil)
        expect(blast.last_email_delivery_latency).to be_nil
      end
    end

    describe "#deliveries_per_minute" do
      it "returns the deliveries per minute" do
        # 1500 deliveries in 10 minutes = 150 deliveries per minute
        expect(blast.deliveries_per_minute).to eq(150.0)
      end

      it "returns nil if last_email_delivered_at is nil" do
        blast.update!(last_email_delivered_at: nil)
        expect(blast.deliveries_per_minute).to be_nil
      end

      it "returns nil if first_email_delivered_at is nil" do
        blast.update!(first_email_delivered_at: nil)
        expect(blast.deliveries_per_minute).to be_nil
      end
    end
  end

  describe ".acknowledge_email_delivery" do
    let(:blast) { create(:post_email_blast, :just_requested) }

    it "sets first_email_delivered_at and last_email_delivered_at to the current time and increment deliveries count", :freeze_time do
      described_class.acknowledge_email_delivery(blast.id)
      blast.reload
      expect(blast.first_email_delivered_at).to eq(Time.current)
      expect(blast.last_email_delivered_at).to eq(Time.current)
      expect(blast.delivery_count).to eq(1)
    end

    it "called twice only updates last_email_delivered_at to the current time" do
      current_time = Time.current

      travel_to current_time do
        described_class.acknowledge_email_delivery(blast.id)
      end

      travel_to current_time + 1.hour do
        described_class.acknowledge_email_delivery(blast.id)
        blast.reload
        expect(blast.first_email_delivered_at).to eq(1.hour.ago)
        expect(blast.last_email_delivered_at).to eq(Time.current)
        expect(blast.delivery_count).to eq(2)
      end
    end
  end

  describe ".format_latency" do
    it "returns a string with the latency in minutes and seconds" do
      expect(described_class.format_latency(0)).to eq("0s")
      expect(described_class.format_latency(30)).to eq("30s")
      expect(described_class.format_latency(1.minute)).to eq("1m 0s")
      expect(described_class.format_latency(1.hour)).to eq("1h 0m 0s")
      expect(described_class.format_latency(1.hour + 1.minute + 1.second)).to eq("1h 1m 1s")
    end

    it "returns nil if the latency is nil" do
      expect(described_class.format_latency(nil)).to be_nil
    end
  end

  describe ".format_datetime" do
    it "returns a string without the timezone" do
      expect(described_class.format_datetime(Time.zone.local(2001, 2, 3, 4, 5, 6))).to eq("2001-02-03 04:05:06")
    end

    it "returns nil if the datetime is nil" do
      expect(described_class.format_datetime(nil)).to be_nil
    end
  end
end
