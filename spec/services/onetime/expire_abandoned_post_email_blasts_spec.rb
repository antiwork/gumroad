# frozen_string_literal: true

require "spec_helper"

describe Onetime::ExpireAbandonedPostEmailBlasts do
  describe ".process" do
    let(:post) { create(:installment) }

    def unsent_blast(post: self.post, requested_at: 3.years.ago, **attrs)
      create(:post_email_blast, :just_requested, post:, requested_at:, **attrs)
    end

    it "reports the blasts it would end without changing them in a dry run" do
      blast = unsent_blast
      expect(ReplicaLagWatcher).not_to receive(:watch)

      expect(described_class.process).to eq([blast.id])

      expect(blast.reload.expired_at).to be_nil
    end

    it "ends never-sent blasts older than the lookback as abandoned, in batches" do
      blasts = [unsent_blast, unsent_blast(requested_at: (AlertOnStalledPostEmailBlastsJob::LOOKBACK + 1.day).ago)]

      expect(described_class.process(dry_run: false, batch_size: 1)).to match_array(blasts.map(&:id))

      blasts.each(&:reload)
      expect(blasts.map(&:expired_at)).to all(be_present)
      expect(blasts.map(&:expiry_reason)).to all(eq(PostEmailBlast::EXPIRY_ABANDONED))
      expect(blasts.map(&:delivery_status)).to all(eq("abandoned"))
    end

    it "still ends a blast whose post only recorded recipients before it was requested" do
      blast = unsent_blast
      SentPostEmail.create!(post:, email: "buyer@example.com", created_at: blast.requested_at - 1.day)

      expect(described_class.process(dry_run: false)).to eq([blast.id])
    end

    it "leaves alone blasts that sent, completed, are resends, or are inside the lookback" do
      delivered = unsent_blast(first_email_delivered_at: 3.years.ago, delivery_count: 3)
      completed = unsent_blast(completed_at: 3.years.ago)
      resend = unsent_blast(recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED)
      recent = unsent_blast(requested_at: 1.day.ago)
      recorded = unsent_blast(post: create(:installment))
      SentPostEmail.create!(post: recorded.post, email: "buyer@example.com", created_at: recorded.requested_at + 1.minute)

      expect(described_class.process(dry_run: false)).to eq([])

      expect([delivered, completed, resend, recent, recorded].map { _1.reload.expired_at }).to all(be_nil)
    end

    it "keeps the reason of a blast that already expired" do
      blast = unsent_blast(expired_at: 3.years.ago, expiry_reason: PostEmailBlast::EXPIRY_QUOTA)

      expect(described_class.process(dry_run: false)).to eq([])

      expect(blast.reload.expiry_reason).to eq(PostEmailBlast::EXPIRY_QUOTA)
    end
  end
end
