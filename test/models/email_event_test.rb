# frozen_string_literal: true

require "test_helper"

class EmailEventTest < ActiveSupport::TestCase
  self.described_class = EmailEvent



  context_ EmailEvent do
    let(:emails) { ["one@example.com", "two@example.com", "three@example.com"] }
    let(:emails_digests) { emails.map { Digest::SHA1.hexdigest(_1).first(12) } }
    let(:email) { emails.first }
    let(:email_digest) { emails_digests.first }
    let(:timestamp) { Time.current }

  context_ ".log_send_events" do
  context_ "when email logging is enabled" do
  test "logs email sent event" do
          # create a new record (passing an email as a string)
          described_class.log_send_events(emails.first, timestamp)

          expect(EmailEvent.count).to eq 1
          record = EmailEvent.find_by(email_digest: emails_digests.first)
          expect(record.sent_emails_count).to eq 1
          expect(record.unopened_emails_count).to eq 1
          expect(record.last_email_sent_at.to_i).to eq timestamp.to_i
          expect(record.first_unopened_email_sent_at.to_i).to eq timestamp.to_i

          # create a new record and update the existing one (passing an array of emails)
          timestamp_2 = 1.minute.from_now
          described_class.log_send_events(emails.first(2), timestamp_2)
          expect(EmailEvent.count).to eq 2

          record = EmailEvent.find_by(email_digest: emails_digests.first)
          expect(record.sent_emails_count).to eq 2
          expect(record.unopened_emails_count).to eq 2
          expect(record.last_email_sent_at.to_i).to eq timestamp_2.to_i
          expect(record.first_unopened_email_sent_at.to_i).to eq timestamp.to_i

          record = EmailEvent.find_by(email_digest: emails_digests.second)
          expect(record.sent_emails_count).to eq 1
          expect(record.unopened_emails_count).to eq 1
          expect(record.last_email_sent_at.to_i).to eq timestamp_2.to_i
          expect(record.first_unopened_email_sent_at.to_i).to eq timestamp_2.to_i

          # create a new record and updates two existing ones
          timestamp_3 = 2.minutes.from_now
          described_class.log_send_events(emails, timestamp_3)
          expect(EmailEvent.count).to eq 3

          record = EmailEvent.find_by(email_digest: emails_digests.first)
          expect(record.sent_emails_count).to eq 3
          expect(record.unopened_emails_count).to eq 3
          expect(record.last_email_sent_at.to_i).to eq timestamp_3.to_i
          expect(record.first_unopened_email_sent_at.to_i).to eq timestamp.to_i

          record = EmailEvent.find_by(email_digest: emails_digests.second)
          expect(record.sent_emails_count).to eq 2
          expect(record.unopened_emails_count).to eq 2
          expect(record.last_email_sent_at.to_i).to eq timestamp_3.to_i
          expect(record.first_unopened_email_sent_at.to_i).to eq timestamp_2.to_i

          record = EmailEvent.find_by(email_digest: emails_digests.third)
          expect(record.sent_emails_count).to eq 1
          expect(record.unopened_emails_count).to eq 1
          expect(record.last_email_sent_at.to_i).to eq timestamp_3.to_i
          expect(record.first_unopened_email_sent_at.to_i).to eq timestamp_3.to_i
        end
      end

  context_ "when email logging is disabled" do
        before do
          Feature.deactivate(:log_email_events)
        end

  test "doesn't log email sent event" do
          described_class.log_send_events(email, timestamp)

          record = EmailEvent.find_by(email_digest:)
          expect(record).to be_nil
        end
      end
    end

  context_ ".log_open_event" do
  context_ "when email logging is disabled" do
        before do
          described_class.log_send_events(email, timestamp)
          Feature.deactivate(:log_email_events)
        end

  test "doesn't log email open event" do
          expect(described_class.log_open_event(email, timestamp)).to be_nil
        end
      end

  context_ "when email logging is enabled" do
  context_ "when EmailEvent record doesn't exist" do
  test "returns nil" do
            expect(described_class.log_open_event(email, timestamp)).to be_nil
          end
        end

  context_ "when EmailEvent record exists" do
          before do
            described_class.log_send_events(email, timestamp)
          end

  test "logs email open event" do
            described_class.log_open_event(email, timestamp)

            record = EmailEvent.find_by(email_digest:)
            expect(record.open_count).to eq 1
            expect(record.unopened_emails_count).to eq 0
            expect(record.first_unopened_email_sent_at).to be_nil
            expect(record.last_opened_at.to_i).to eq timestamp.to_i
          end
        end
      end
    end

  context_ ".log_click_event" do
  context_ "when email logging is disabled" do
        before do
          described_class.log_send_events(email, timestamp)
          Feature.deactivate(:log_email_events)
        end

  test "doesn't log email click event" do
          expect(described_class.log_click_event(email, timestamp)).to be_nil
        end
      end

  context_ "when email logging is enabled" do
  context_ "when EmailEvent record doesn't exist" do
  test "returns nil" do
            expect(described_class.log_click_event(email, timestamp)).to be_nil
          end
        end

  context_ "when EmailEvent record exists" do
          before do
            described_class.log_send_events(email, timestamp)
          end

  test "logs email click event" do
            described_class.log_click_event(email, timestamp)

            record = EmailEvent.find_by(email_digest:)
            expect(record.click_count).to eq 1
            expect(record.last_clicked_at.to_i).to eq timestamp.to_i
          end
        end
      end
    end

  context_ ".stale_recipient?" do
  context_ "when EmailEvent record doesn't exist" do
  test "returns false" do
          expect(described_class.stale_recipient?(email)).to be false
        end
      end

  context_ "when EmailEvent record exists" do
        before do
          described_class.log_send_events(email, timestamp)
        end

  context_ "when first_unopened_email_sent_at is nil" do
          before do
            described_class.log_open_event(email, timestamp)
          end

  test "returns false" do
            expect(described_class.stale_recipient?(email)).to be false
          end
        end

  context_ "when first_unopened_email_sent_at is within threshold" do
          before do
            event = EmailEvent.find_by(email_digest:)
            event.update!(first_unopened_email_sent_at: 364.days.ago)
          end

  test "returns false" do
            expect(described_class.stale_recipient?(email)).to be false
          end
        end

  context_ "when first_unopened_email_sent_at is beyond threshold" do
          before do
            event = EmailEvent.find_by(email_digest:)
            event.update!(first_unopened_email_sent_at: 366.days.ago)
          end

  context_ "when unopened_emails_count is below threshold" do
            before do
              event = EmailEvent.find_by(email_digest:)
              event.update!(unopened_emails_count: 9)
            end

  test "returns false" do
              expect(described_class.stale_recipient?(email)).to be false
            end
          end

  context_ "when unopened_emails_count meets threshold" do
            before do
              event = EmailEvent.find_by(email_digest:)
              event.update!(unopened_emails_count: 10)
            end

  context_ "when last_clicked_at is within threshold" do
              before do
                event = EmailEvent.find_by(email_digest:)
                event.update!(last_clicked_at: 364.days.ago)
              end

  test "returns false" do
                expect(described_class.stale_recipient?(email)).to be false
              end
            end

  context_ "when last_clicked_at is beyond threshold" do
              before do
                event = EmailEvent.find_by(email_digest:)
                event.update!(last_clicked_at: 366.days.ago)
              end

  test "returns true" do
                expect(described_class.stale_recipient?(email)).to be true
              end
            end

  context_ "when last_clicked_at is nil" do
  test "returns true" do
                expect(described_class.stale_recipient?(email)).to be true
              end
            end
          end
        end
      end
    end

  context_ ".mark_as_stale" do
  context_ "when EmailEvent record doesn't exist" do
  test "returns nil" do
          expect(described_class.mark_as_stale(email, timestamp)).to be_nil
        end
      end

  context_ "when EmailEvent record exists" do
        before do
          described_class.log_send_events(email, timestamp)
        end

  test "marks the record as stale" do
          described_class.mark_as_stale(email, timestamp)

          record = EmailEvent.find_by(email_digest:)
          expect(record.marked_as_stale_at.to_i).to eq timestamp.to_i
        end
      end
    end
  end
end
