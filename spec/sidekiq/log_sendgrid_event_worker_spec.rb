# frozen_string_literal: true

describe LogSendgridEventWorker do
  describe "#perform" do
    let(:email) { "example@example.com" }
    let(:email_digest) { Digest::SHA1.hexdigest(email).first(12) }
    let(:event_timestamp) { 5.minutes.from_now }

    before do
      Feature.activate(:log_email_events)
      EmailEvent.log_send_events(email, Time.current)
    end

    it "logs open event" do
      params = { "_json" => [{ "event" => "open", "email" => email, "timestamp" => event_timestamp }] }
      described_class.new.perform(params)

      record = EmailEvent.find_by(email_digest:)
      expect(record.open_count).to eq 1
      expect(record.unopened_emails_count).to eq 0
      expect(record.first_unopened_email_sent_at).to be_nil
      expect(record.last_opened_at.to_i).to eq event_timestamp.to_i
    end

    it "logs click event" do
      params = { "_json" => [{ "event" => "click", "email" => email, "timestamp" => event_timestamp }] }
      described_class.new.perform(params)

      record = EmailEvent.find_by(email_digest:)
      expect(record.click_count).to eq 1
      expect(record.last_clicked_at.to_i).to eq event_timestamp.to_i
    end
  end
end
