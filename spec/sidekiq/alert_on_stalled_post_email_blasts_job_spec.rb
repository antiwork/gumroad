# frozen_string_literal: true

require "spec_helper"

describe AlertOnStalledPostEmailBlastsJob do
  let(:post) { create(:installment) }

  def post_with_audience
    post = create(:audience_post, :published)
    create(:active_follower, user: post.seller)
    post
  end

  def snapshotted_recipient_for(blast)
    AudienceMember.where(seller_id: blast.seller_id).sole
  end

  def stalled_blast(requested_hours_ago: 6, post: self.post, delivery_count: 0, started: true)
    requested_at = requested_hours_ago.hours.ago
    create(:post_email_blast, post:, requested_at:, started_at: started ? requested_at + 1.minute : nil,
                              completed_at: nil, delivery_count:)
  end

  def stub_sidekiq(dead: [], retrying: [], busy: [], queued: [])
    @dead_jobs = dead.index_with { |id| fake_sidekiq_job(id) }
    dead_set = instance_double(Sidekiq::DeadSet)
    allow(Sidekiq::DeadSet).to receive(:new).and_return(dead_set)
    allow(dead_set).to receive(:scan) do |_match, &block|
      @dead_jobs.each_value { |job| block.call(job) }
    end

    retry_set = instance_double(Sidekiq::RetrySet)
    allow(Sidekiq::RetrySet).to receive(:new).and_return(retry_set)
    allow(retry_set).to receive(:scan) do |_match, &block|
      retrying.each { |id| block.call(fake_sidekiq_job(id)) }
    end

    queue = queued.map { |id| fake_sidekiq_job(id) }
    allow(Sidekiq::Queue).to receive(:new).with("default").and_return(queue)

    workers = instance_double(Sidekiq::Workers)
    allow(Sidekiq::Workers).to receive(:new).and_return(workers)
    allow(workers).to receive(:each) do |&block|
      busy.each do |id|
        # Production hands the payload back as a JSON string, so the fixture does too.
        block.call("pid", "tid", { "payload" => { "class" => "SendPostBlastEmailsJob", "args" => [id] }.to_json })
      end
    end
  end

  def fake_sidekiq_job(blast_id)
    instance_double(Sidekiq::SortedEntry, klass: "SendPostBlastEmailsJob", args: [blast_id], retry: nil)
  end

  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
    allow(SendPostBlastEmailsJob).to receive(:perform_async)
  end

  it "reports a stalled blast with its dead-set disposition and per-blast delivered count" do
    blast = stalled_blast(delivery_count: 6800)
    stub_sidekiq(dead: [blast.id])

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |room, subject, message|
      expect(room).to eq("payments")
      expect(subject).to eq("Stalled post email blasts")
      expect(message).to include("1 email blast requested more than")
      expect(message).to include("blast #{blast.id}")
      expect(message).to include("6800 delivered, DEAD")
    end
  end

  it "stays silent when every blast completed or is under the stall threshold" do
    create(:post_email_blast, post:, requested_at: 6.hours.ago, started_at: 6.hours.ago, completed_at: 5.hours.ago)
    create(:post_email_blast, post:, requested_at: 1.hour.ago, started_at: 1.hour.ago, completed_at: nil)
    stub_sidekiq

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "ignores stalls older than the lookback so historical rows do not bury new ones" do
    stalled_blast(requested_hours_ago: 15 * 24)
    stub_sidekiq

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "reports a blast whose send job never ran at all" do
    blast = stalled_blast(started: false)
    stub_sidekiq

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to match(/blast #{blast.id}.*\[never started\].*UNACCOUNTED/)
    end
  end

  it "distinguishes running, queued, retrying and unaccounted blasts" do
    running = stalled_blast
    queued = stalled_blast(post: create(:installment))
    retrying = stalled_blast(post: create(:installment))
    lost = stalled_blast(post: create(:installment))
    stub_sidekiq(busy: [running.id], queued: [queued.id], retrying: [retrying.id])

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to match(/blast #{running.id}.*RUNNING/)
      expect(message).to match(/blast #{queued.id}.*QUEUED/)
      expect(message).to match(/blast #{retrying.id}.*RETRYING/)
      expect(message).to match(/blast #{lost.id}.*UNACCOUNTED/)
    end
  end

  it "says the scan was truncated instead of presenting a cut page as the total" do
    stub_const("#{described_class}::MAX_CANDIDATES_SCANNED", 1)
    stalled_blast
    stalled_blast(post: create(:installment))
    stub_sidekiq

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("At least 1 email blast")
      expect(message).to include("The scan stopped at 1 incomplete blasts")
    end
  end

  describe "auto-resume" do
    context "when :auto_resume_stalled_post_blasts is active" do
      before { Feature.activate(:auto_resume_stalled_post_blasts) }
      after { Feature.deactivate(:auto_resume_stalled_post_blasts) }

      it "retries a DEAD blast inside the resume window and marks it resumed once" do
        blast = stalled_blast(requested_hours_ago: 6)
        stub_sidekiq(dead: [blast.id])

        described_class.new.perform

        expect(@dead_jobs.fetch(blast.id)).to have_received(:retry)
        expect($redis.exists?(RedisKey.stalled_blast_auto_resumed(blast.id))).to be(true)
        expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
          expect(message).to match(/blast #{blast.id}.*DEAD → RESUMED/)
        end
      end

      it "re-enqueues an UNACCOUNTED blast inside the resume window" do
        blast = stalled_blast(requested_hours_ago: 6)
        stub_sidekiq

        described_class.new.perform

        expect(SendPostBlastEmailsJob).to have_received(:perform_async).with(blast.id)
        expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
          expect(message).to match(/blast #{blast.id}.*UNACCOUNTED → RESUMED/)
        end
      end

      it "holds a blast past the resume window for a human" do
        blast = stalled_blast(requested_hours_ago: 30)
        stub_sidekiq(dead: [blast.id])

        described_class.new.perform

        expect(@dead_jobs.fetch(blast.id)).not_to have_received(:retry)
        expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
          expect(message).to match(/blast #{blast.id}.*HELD \(past/)
        end
      end

      it "never resumes the same blast twice" do
        blast = stalled_blast(requested_hours_ago: 6)
        $redis.set(RedisKey.stalled_blast_auto_resumed(blast.id), Time.current.iso8601)
        stub_sidekiq

        described_class.new.perform

        expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
        expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
          expect(message).to match(/blast #{blast.id}.*HELD \(already auto-resumed/)
        end
      end

      it "holds the blast when a concurrent run wins the NX claim between the check and the resume" do
        blast = stalled_blast(requested_hours_ago: 6)
        stub_sidekiq
        marker = RedisKey.stalled_blast_auto_resumed(blast.id)
        allow($redis).to receive(:exists?).and_call_original
        allow($redis).to receive(:exists?).with(marker).and_return(false)
        allow($redis).to receive(:set).with(marker, anything, hash_including(nx: true)).and_return(false)

        described_class.new.perform

        expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
        expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
          expect(message).to match(/blast #{blast.id}.*HELD \(already auto-resumed/)
        end
      end

      it "never auto-resumes an UNACCOUNTED non-opener resend, even inside the window" do
        blast = stalled_blast(requested_hours_ago: 6)
        blast.update!(recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED)
        stub_sidekiq

        described_class.new.perform

        expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
        expect($redis.exists?(RedisKey.stalled_blast_auto_resumed(blast.id))).to be(false)
        expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
          expect(message).to match(/blast #{blast.id}.*UNACCOUNTED → HELD \(non-opener/)
        end
      end

      it "still retries a DEAD non-opener resend, since its dead entry proves no sender is running" do
        blast = stalled_blast(requested_hours_ago: 6)
        blast.update!(recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED)
        stub_sidekiq(dead: [blast.id])

        described_class.new.perform

        expect(@dead_jobs.fetch(blast.id)).to have_received(:retry)
      end

      it "skips the resume without burning the once-per-blast marker when the sender reappears at action time" do
        blast = stalled_blast(requested_hours_ago: 6)
        stub_sidekiq
        job = described_class.new
        allow(job).to receive(:busy_blast_ids).and_return([], [blast.id])

        job.perform

        expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
        expect($redis.exists?(RedisKey.stalled_blast_auto_resumed(blast.id))).to be(false)
        expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
          expect(message).to match(/blast #{blast.id}.*UNACCOUNTED → SKIPPED \(sender reappeared/)
        end
      end

      it "does not touch RUNNING, QUEUED, or RETRYING blasts" do
        running = stalled_blast
        queued_blast = stalled_blast(post: create(:installment))
        retrying = stalled_blast(post: create(:installment))
        stub_sidekiq(busy: [running.id], queued: [queued_blast.id], retrying: [retrying.id])

        described_class.new.perform

        expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
        expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
          expect(message).not_to include("RESUMED")
        end
      end
    end

    it "stamps completed_at on a fully delivered DEAD blast instead of retrying it" do
      blast = stalled_blast(requested_hours_ago: 6, post: post_with_audience, delivery_count: 3)
      recipient = snapshotted_recipient_for(blast)
      $redis.rpush(RedisKey.blast_audience_snapshot(blast.id), recipient.id)
      SentPostEmail.create!(post: blast.post, email: recipient.email)
      stub_sidekiq(dead: [blast.id])

      described_class.new.perform

      expect(@dead_jobs.fetch(blast.id)).not_to have_received(:retry)
      expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
      expect(blast.reload.completed_at).to be_present
      expect($redis.exists?(RedisKey.blast_audience_snapshot(blast.id))).to be(false)
      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
        expect(message).to match(/blast #{blast.id}.*DEAD → COMPLETED/)
      end
    end

    it "completes a fully delivered blast past the resume window and when the resume flag is off" do
      blast = stalled_blast(requested_hours_ago: 30, post: post_with_audience, delivery_count: 3)
      recipient = snapshotted_recipient_for(blast)
      $redis.rpush(RedisKey.blast_audience_snapshot(blast.id), recipient.id)
      SentPostEmail.create!(post: blast.post, email: recipient.email)
      stub_sidekiq(dead: [blast.id])

      described_class.new.perform

      expect(@dead_jobs.fetch(blast.id)).not_to have_received(:retry)
      expect(blast.reload.completed_at).to be_present
    end

    it "does not complete a fully delivered blast when its sender reappears at action time" do
      blast = stalled_blast(requested_hours_ago: 6, post: post_with_audience, delivery_count: 3)
      recipient = snapshotted_recipient_for(blast)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)
      $redis.rpush(snapshot_key, recipient.id)
      SentPostEmail.create!(post: blast.post, email: recipient.email)
      stub_sidekiq
      job = described_class.new
      allow(job).to receive(:busy_blast_ids).and_return([], [blast.id])

      job.perform

      expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
      expect(blast.reload.completed_at).to be_nil
      expect($redis.exists?(snapshot_key)).to be(true)
      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
        expect(message).to match(/blast #{blast.id}.*UNACCOUNTED → SKIPPED \(sender reappeared/)
      end
    end

    it "does not complete after a delivery query if the sender appears during that query" do
      blast = stalled_blast(requested_hours_ago: 6, post: post_with_audience, delivery_count: 3)
      recipient = snapshotted_recipient_for(blast)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)
      $redis.rpush(snapshot_key, recipient.id)
      SentPostEmail.create!(post: blast.post, email: recipient.email)
      stub_sidekiq
      job = described_class.new
      allow(job).to receive(:busy_blast_ids).and_return([], [], [blast.id])

      job.perform

      expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
      expect(blast.reload.completed_at).to be_nil
      expect($redis.exists?(snapshot_key)).to be(true)
      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
        expect(message).to match(/blast #{blast.id}.*UNACCOUNTED → SKIPPED \(sender reappeared/)
      end
    end

    it "does not complete when another action already owns the completion claim" do
      blast = stalled_blast(requested_hours_ago: 6, post: post_with_audience, delivery_count: 3)
      recipient = snapshotted_recipient_for(blast)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)
      $redis.rpush(snapshot_key, recipient.id)
      $redis.set(RedisKey.blast_completion_stamp_claim(blast.id), Time.current.iso8601)
      SentPostEmail.create!(post: blast.post, email: recipient.email)
      stub_sidekiq

      described_class.new.perform

      expect(blast.reload.completed_at).to be_nil
      expect($redis.exists?(snapshot_key)).to be(true)
      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
        expect(message).not_to include("COMPLETED")
      end
    ensure
      $redis.del(RedisKey.blast_completion_stamp_claim(blast.id), snapshot_key) if blast && snapshot_key
    end

    it "does not complete when a sender has started before it becomes visible in Sidekiq" do
      blast = stalled_blast(requested_hours_ago: 6, post: post_with_audience, delivery_count: 3)
      recipient = snapshotted_recipient_for(blast)
      snapshot_key = RedisKey.blast_audience_snapshot(blast.id)
      $redis.rpush(snapshot_key, recipient.id)
      $redis.set(RedisKey.blast_send_attempt_claim(blast.id), SecureRandom.uuid, ex: 4.hours.to_i)
      SentPostEmail.create!(post: blast.post, email: recipient.email)
      stub_sidekiq

      described_class.new.perform

      expect(blast.reload.completed_at).to be_nil
      expect($redis.exists?(snapshot_key)).to be(true)
      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
        expect(message).to match(/blast #{blast.id}.*UNACCOUNTED → SKIPPED \(sender reappeared/)
      end
    ensure
      $redis.del(RedisKey.blast_send_attempt_claim(blast.id), snapshot_key) if blast && snapshot_key
    end

    it "does not resume after a delivery miss if the sender appears before the claim" do
      blast = stalled_blast(requested_hours_ago: 6)
      stub_sidekiq
      Feature.activate(:auto_resume_stalled_post_blasts)
      job = described_class.new
      allow(job).to receive(:busy_blast_ids).and_return([], [], [blast.id])

      job.perform

      expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
      expect($redis.exists?(RedisKey.stalled_blast_auto_resumed(blast.id))).to be(false)
      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
        expect(message).to match(/blast #{blast.id}.*UNACCOUNTED → SKIPPED \(sender reappeared/)
      end
    ensure
      Feature.deactivate(:auto_resume_stalled_post_blasts)
    end

    it "does not treat a partial send as fully delivered" do
      blast = stalled_blast(requested_hours_ago: 6, post: post_with_audience, delivery_count: 3)
      recipient = snapshotted_recipient_for(blast)
      $redis.rpush(RedisKey.blast_audience_snapshot(blast.id), recipient.id)
      stub_sidekiq(dead: [blast.id])

      described_class.new.perform

      expect(blast.reload.completed_at).to be_nil
      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
        expect(message).not_to include("COMPLETED")
      end
    end

    context "when the flag is off" do
      it "never truncates action rows out of the report" do
        stub_const("#{described_class}::MAX_REPORTED", 1)
        resumable = stalled_blast(requested_hours_ago: 6)
        running = stalled_blast(requested_hours_ago: 5, post: create(:installment))
        stub_sidekiq(busy: [running.id])

        described_class.new.perform

        expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
          expect(message).to match(/blast #{resumable.id}.*WOULD RESUME/)
          expect(message).to include("…and 1 more.")
        end
      end

      it "reports WOULD RESUME without touching anything" do
        blast = stalled_blast(requested_hours_ago: 6)
        stub_sidekiq(dead: [blast.id])

        described_class.new.perform

        expect(@dead_jobs.fetch(blast.id)).not_to have_received(:retry)
        expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
        expect($redis.exists?(RedisKey.stalled_blast_auto_resumed(blast.id))).to be(false)
        expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
          expect(message).to include("Auto-resume is DRY RUN")
          expect(message).to match(/blast #{blast.id}.*DEAD → WOULD RESUME/)
        end
      end
    end
  end
end
