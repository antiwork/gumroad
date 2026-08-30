# frozen_string_literal: true

require "spec_helper"

describe AlertOnStalledAbandonedCartEmailsJob do
  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
  end

  def sent_email_at(time)
    travel_to(time) { create(:sent_abandoned_cart_email) }
  end

  describe "#perform" do
    it "stays quiet when a send landed inside the threshold" do
      sent_email_at(2.hours.ago)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end

    it "stays quiet on the near side of the threshold" do
      sent_email_at(described_class::STALL_THRESHOLD.ago + 1.hour)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end

    it "alerts once the newest send is older than the threshold" do
      last_sent_at = described_class::STALL_THRESHOLD.ago - 1.hour
      sent_email_at(last_sent_at)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |room, _sender, message|
        expect(room).to eq("agent_reports")
        expect(message).to include(last_sent_at.utc.strftime("%Y-%m-%d %H:%M UTC"))
        expect(message).to include("25 hours")
      end
    end

    it "alerts when nothing has ever been sent" do
      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include("has ever been sent")
      end
    end

    it "names the room and sender it reports to" do
      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async)
        .with("agent_reports", "Abandoned cart emails stalled", anything)
    end

    it "judges freshness on the newest send, not the oldest" do
      # A stalled surface still has old rows; reading anything but the newest would report a
      # platform-wide outage as healthy, which is the failure this job exists to catch.
      sent_email_at(10.days.ago)
      sent_email_at(1.hour.ago)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end
  end

  describe "schedule" do
    let(:schedule) { YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml")) }

    def cron_for(job_class_name)
      schedule.values.find { |entry| entry["class"] == job_class_name }&.fetch("cron")
    end

    it "is registered on the schedule so it actually runs" do
      expect(schedule.values.map { |entry| entry["class"] }).to include(described_class.name)
    end

    # Reading freshness before the day's send has had a chance to write anything would report
    # every healthy day as an outage, so the alert has to sit after the job it watches.
    it "runs later in the day than the send job it watches" do
      send_hour = cron_for("ScheduleAbandonedCartEmailsJob").split[1].to_i
      alert_hour = cron_for(described_class.name).split[1].to_i

      expect(alert_hour).to be > send_hour
    end
  end

  # Every example above stubs the worker, so nothing else would notice the room going away —
  # and InternalNotificationMailer#notify returns silently when the room has no recipient, which
  # would leave this job permanently dark with all specs green.
  it "sends to a room that resolves to a real recipient" do
    mail = InternalNotificationMailer.notify(room_name: "agent_reports", sender: "spec", message_text: "hello")

    expect(mail.to).to be_present
  end
end
