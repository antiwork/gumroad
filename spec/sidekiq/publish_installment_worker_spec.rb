# frozen_string_literal: true

describe PublishInstallmentWorker do
  before do
    @post = create(:audience_installment)
  end

  describe "#perform" do
    context "with a blast" do
      before do
        @blast = create(:post_email_blast, post: @post)
      end

      it "enqueues a SendPostBlastEmailsJob" do
        described_class.new.perform(@post.id, @blast.id, nil)
        expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(@blast.id)
        expect(PublishScheduledPostJob.jobs).to be_empty
      end
    end

    context "without a blast (logically, a scheduled post)" do
      before do
        @rule = create(:installment_rule, installment: @post, to_be_published_at: 1.week.from_now)
      end

      it "enqueues a PublishScheduledPostJob" do
        described_class.new.perform(@post.id, nil, @rule.version)
        expect(PublishScheduledPostJob).to have_enqueued_sidekiq_job(@post.id, @rule.version)
        expect(SendPostBlastEmailsJob.jobs).to be_empty
      end
    end
  end
end
