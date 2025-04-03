# frozen_string_literal: true

describe LogResendEventJob do
  describe "#perform" do
    let(:email) { "example@example.com" }
    let(:email_digest) { Digest::SHA1.hexdigest(email).first(12) }
    let(:event_timestamp) { 5.minutes.from_now }

    before do
      Feature.activate(:log_email_events)
      EmailEvent.log_send_events(email, Time.current)
    end

    it "logs open event" do
      params = {
        "type" => "email.opened",
        "created_at" => "2024-02-22T23:41:12.126Z",
        "data" => {
          "created_at" => event_timestamp.to_s,
          "email_id" => "56761188-7520-42d8-8898-ff6fc54ce618",
          "from" => "Acme <onboarding@resend.dev>",
          "to" => [email],
          "subject" => "Sending this example",
          "headers" => [
            {
              "name" => MailerInfo.header_name(:mailer_class),
              "value" => MailerInfo.encrypt("Mailer")
            },
            {
              "name" => MailerInfo.header_name(:mailer_method),
              "value" => MailerInfo.encrypt("method")
            },
          ]
        }
      }
      described_class.new.perform(params)

      record = EmailEvent.find_by(email_digest:)
      expect(record.open_count).to eq 1
      expect(record.unopened_emails_count).to eq 0
      expect(record.first_unopened_email_sent_at).to be_nil
      expect(record.last_opened_at.to_i).to eq event_timestamp.to_i
    end

    it "logs click event" do
      params = {
        "type" => "email.clicked",
        "created_at" => "2024-11-22T23:41:12.126Z",
        "data" => {
          "created_at" => event_timestamp.to_s,
          "email_id" => "56761188-7520-42d8-8898-ff6fc54ce618",
          "from" => "Acme <onboarding@resend.dev>",
          "to" => [email],
          "click" => {
            "ipAddress" => "122.115.53.11",
            "link" => "https://resend.com",
            "timestamp" => "2024-11-24T05:00:57.163Z",
            "userAgent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.1 Safari/605.1.15"
          },
          "subject" => "Sending this example",
          "headers" => [
            {
              "name" => MailerInfo.header_name(:mailer_class),
              "value" => MailerInfo.encrypt("Mailer")
            },
            {
              "name" => MailerInfo.header_name(:mailer_method),
              "value" => MailerInfo.encrypt("method")
            },
          ]
        }
      }
      described_class.new.perform(params)

      record = EmailEvent.find_by(email_digest:)
      expect(record.click_count).to eq 1
      expect(record.last_clicked_at.to_i).to eq event_timestamp.to_i
    end

    it "ignores other event types" do
      params = {
        "type" => "email.delivered",
        "created_at" => "2024-02-22T23:41:12.126Z",
        "data" => {
          "created_at" => event_timestamp.to_s,
          "email_id" => "56761188-7520-42d8-8898-ff6fc54ce618",
          "from" => "Acme <onboarding@resend.dev>",
          "to" => [email],
          "subject" => "Sending this example",
          "headers" => [
            {
              "name" => MailerInfo.header_name(:mailer_class),
              "value" => MailerInfo.encrypt("Mailer")
            },
            {
              "name" => MailerInfo.header_name(:mailer_method),
              "value" => MailerInfo.encrypt("method")
            },
          ]
        }
      }
      described_class.new.perform(params)

      record = EmailEvent.find_by(email_digest:)
      expect(record.open_count).to eq 0
      expect(record.click_count).to eq 0
    end
  end
end
