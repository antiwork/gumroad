# frozen_string_literal: true

describe PublishScheduledPostJob, :freeze_time do
  before do
    @post = create(:audience_installment, shown_on_profile: true, send_emails: true)
    @rule = create(:installment_rule, installment: @post)
  end

  describe "#perform" do
    it "publishes post, creates a blast and enqueues SendPostBlastEmailsJob when send_emails? is true" do
      described_class.new.perform(@post.id, @rule.version)

      expect(@post.reload.published?).to eq(true)
      blast = PostEmailBlast.where(post: @post).last!
      expect(blast.requested_at).to eq(@rule.to_be_published_at)
      expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(blast.id)
    end

    it "publishes post but does not create a blast when there was already one" do
      create(:blast, post: @post)
      expect do
        described_class.new.perform(@post.id, @rule.version)
      end.not_to change(PostEmailBlast, :count)

      expect(@post.reload.published?).to eq(true)
      expect(SendPostBlastEmailsJob.jobs).to be_empty
    end

    it "publishes post but does not enqueue SendPostBlastEmailsJob when send_emails? is false" do
      @post.update!(send_emails: false)
      described_class.new.perform(@post.id, @rule.version)

      expect(@post.reload.published?).to eq(true)
      expect(SendPostBlastEmailsJob.jobs).to be_empty
    end

    it "does not publish post if the post is deleted" do
      @post.mark_deleted!
      described_class.new.perform(@post.id, @rule.version)
      expect(@post.reload.published?).to eq(false)
      expect(SendPostBlastEmailsJob.jobs).to be_empty
    end

    it "does not send emails if the post is already published" do
      @post.publish!
      described_class.new.perform(@post.id, @rule.version)
      expect(@post.reload.published?).to eq(true)
      expect(SendPostBlastEmailsJob.jobs).to be_empty
    end

    it "does not publish post if rule has a different version" do
      described_class.new.perform(@post.id, @rule.version + 1)
      expect(@post.reload.published?).to eq(false)
      expect(SendPostBlastEmailsJob.jobs).to be_empty
    end

    it "does not publish post if rule is deleted" do
      @rule.mark_deleted!
      described_class.new.perform(@post.id, @rule.version)
      expect(@post.reload.published?).to eq(false)
      expect(SendPostBlastEmailsJob.jobs).to be_empty
    end
  end
end
