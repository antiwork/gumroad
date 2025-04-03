# frozen_string_literal: true

RSpec.describe Onetime::RemoveStaleRecipients do
  describe ".process" do
    let(:follower) { create(:follower) }
    let(:purchase) { create(:purchase, can_contact: true) }
    let(:timestamp) { Time.current }

    before do
      Feature.activate(:log_email_events)
    end

    context "when processing followers" do
      it "marks stale followers as deleted and records stale timestamp" do
        freeze_time do
          EmailEvent.log_send_events(follower.email, timestamp)
          event = EmailEvent.find_by(email_digest: Digest::SHA1.hexdigest(follower.email).first(12))
          event.update!(
            first_unopened_email_sent_at: 366.days.ago,
            unopened_emails_count: 10
          )

          described_class.process

          expect(follower.reload.deleted?).to be true
          expect(event.reload.marked_as_stale_at).to eq Time.current
        end
      end

      it "does not mark non-stale followers as deleted" do
        freeze_time do
          EmailEvent.log_send_events(follower.email, timestamp)
          event = EmailEvent.find_by(email_digest: Digest::SHA1.hexdigest(follower.email).first(12))
          event.update!(
            first_unopened_email_sent_at: 364.days.ago,
            unopened_emails_count: 10
          )

          described_class.process

          expect(follower.reload.deleted?).to be false
          expect(event.reload.marked_as_stale_at).to be_nil
        end
      end
    end

    context "when processing purchases" do
      it "marks stale purchase emails as uncontactable and records stale timestamp" do
        freeze_time do
          EmailEvent.log_send_events(purchase.email, timestamp)
          event = EmailEvent.find_by(email_digest: Digest::SHA1.hexdigest(purchase.email).first(12))
          event.update!(
            first_unopened_email_sent_at: 366.days.ago,
            unopened_emails_count: 10
          )

          described_class.process

          expect(purchase.reload.can_contact).to be false
          expect(event.reload.marked_as_stale_at).to eq Time.current
        end
      end

      it "does not mark non-stale purchase emails as uncontactable" do
        freeze_time do
          EmailEvent.log_send_events(purchase.email, timestamp)
          event = EmailEvent.find_by(email_digest: Digest::SHA1.hexdigest(purchase.email).first(12))
          event.update!(
            first_unopened_email_sent_at: 364.days.ago,
            unopened_emails_count: 10
          )

          described_class.process

          expect(purchase.reload.can_contact).to be true
          expect(event.reload.marked_as_stale_at).to be_nil
        end
      end
    end
  end
end
