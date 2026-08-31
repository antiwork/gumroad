# frozen_string_literal: true

require "spec_helper"

describe AlertOnStalledPostEmailBlastsJob do
  let(:post) { create(:installment) }

  def stalled_blast(requested_hours_ago: 6, post: self.post, delivery_count: 0, started: true)
    requested_at = requested_hours_ago.hours.ago
    started_at = started ? requested_at + 1.minute : nil
    # Factory default last_email is 10 minutes ago (still-sending). A stalled fixture must
    # look idle or last_email_recent? would classify every candidate as running.
    create(:post_email_blast, post:, requested_at:, started_at:, completed_at: nil, delivery_count:,
                              first_email_delivered_at: started_at, last_email_delivered_at: started_at)
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
    instance_double(Sidekiq::SortedEntry, klass: "SendPostBlastEmailsJob", args: [blast_id], retry: nil, delete: nil)
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

      it "re-enqueues a DEAD blast inside the resume window and marks it resumed once" do
        blast = stalled_blast(requested_hours_ago: 6)
        stub_sidekiq(dead: [blast.id])

        described_class.new.perform

        expect(SendPostBlastEmailsJob).to have_received(:perform_async).with(blast.id)
        expect(@dead_jobs.fetch(blast.id)).to have_received(:delete)
        expect($redis.exists?(RedisKey.stalled_blast_auto_resumed(blast.id))).to be(true)
        expect(InternalNotificationWorker).not_to have_received(:perform_async)
      end

      # `retry` re-pushes the dead entry's ORIGINAL jid, and super_fetch's poison-pill guard
      # counts orphan recoveries per jid — a blast it already killed is killed again before it
      # delivers anything, silently (gumroad-private#2338).
      it "never re-pushes the dead entry's own jid, which super_fetch would kill again" do
        blast = stalled_blast(requested_hours_ago: 6)
        stub_sidekiq(dead: [blast.id])

        described_class.new.perform

        expect(@dead_jobs.fetch(blast.id)).not_to have_received(:retry)
        expect(SendPostBlastEmailsJob).to have_received(:perform_async).with(blast.id)
      end

      # The reverse order can leave a blast with neither a dead entry nor a sender, and an
      # UNACCOUNTED non-opener resend is held for a human indefinitely.
      it "keeps the dead entry when the fresh enqueue fails" do
        blast = stalled_blast(requested_hours_ago: 6)
        stub_sidekiq(dead: [blast.id])
        allow(SendPostBlastEmailsJob).to receive(:perform_async).and_raise(Redis::CannotConnectError)

        expect { described_class.new.perform }.to raise_error(Redis::CannotConnectError)

        expect(@dead_jobs.fetch(blast.id)).not_to have_received(:delete)
      end

      it "re-enqueues an UNACCOUNTED blast inside the resume window" do
        blast = stalled_blast(requested_hours_ago: 6)
        stub_sidekiq

        described_class.new.perform

        expect(SendPostBlastEmailsJob).to have_received(:perform_async).with(blast.id)
        expect(InternalNotificationWorker).not_to have_received(:perform_async)
      end

      it "holds a blast past the resume window for a human" do
        blast = stalled_blast(requested_hours_ago: 30)
        stub_sidekiq(dead: [blast.id])

        described_class.new.perform

        expect(@dead_jobs.fetch(blast.id)).not_to have_received(:delete)
        expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
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

      it "retries again after the resume marker expires" do
        blast = stalled_blast(requested_hours_ago: 6)
        stub_sidekiq

        described_class.new.perform
        expect(SendPostBlastEmailsJob).to have_received(:perform_async).with(blast.id).once

        $redis.del(RedisKey.stalled_blast_auto_resumed(blast.id))
        described_class.new.perform
        expect(SendPostBlastEmailsJob).to have_received(:perform_async).with(blast.id).twice
      end

      it "expires the resume marker after the stall threshold, not the lookback" do
        blast = stalled_blast(requested_hours_ago: 6)
        stub_sidekiq
        allow($redis).to receive(:set).and_call_original
        expect($redis).to receive(:set).with(
          RedisKey.stalled_blast_auto_resumed(blast.id),
          anything,
          hash_including(nx: true, ex: described_class::STALL_THRESHOLD.to_i)
        ).and_call_original

        described_class.new.perform
      end

      it "treats a blast that emailed inside the stall threshold as running even without a Sidekiq worker" do
        blast = stalled_blast(requested_hours_ago: 6)
        blast.update!(last_email_delivered_at: 30.minutes.ago)
        stub_sidekiq

        described_class.new.perform

        expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
        expect($redis.exists?(RedisKey.stalled_blast_auto_resumed(blast.id))).to be(false)
        expect(InternalNotificationWorker).not_to have_received(:perform_async)
      end

      it "resumes a blast past the window when recipients are still owed" do
        blast = stalled_blast(requested_hours_ago: 30)
        $redis.set(RedisKey.blast_pending_recipients(blast.id), 12)
        stub_sidekiq(dead: [blast.id])

        described_class.new.perform

        expect(SendPostBlastEmailsJob).to have_received(:perform_async).with(blast.id)
        expect(@dead_jobs.fetch(blast.id)).to have_received(:delete)
        expect(InternalNotificationWorker).not_to have_received(:perform_async)
      end

      it "holds the blast when a concurrent run wins the NX claim between the check and the resume" do
        blast = stalled_blast(requested_hours_ago: 6)
        stub_sidekiq
        marker = RedisKey.stalled_blast_auto_resumed(blast.id)
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

      it "still resumes a DEAD non-opener resend, since its dead entry proves no sender is running" do
        blast = stalled_blast(requested_hours_ago: 6)
        blast.update!(recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED)
        stub_sidekiq(dead: [blast.id])

        described_class.new.perform

        expect(SendPostBlastEmailsJob).to have_received(:perform_async).with(blast.id)
        expect(@dead_jobs.fetch(blast.id)).to have_received(:delete)
        expect(InternalNotificationWorker).not_to have_received(:perform_async)
      end

      it "skips the resume without burning the once-per-blast marker when the sender reappears at action time" do
        blast = stalled_blast(requested_hours_ago: 6)
        stub_sidekiq
        job = described_class.new
        allow(job).to receive(:busy_blast_ids).and_return([], [blast.id])

        job.perform

        expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
        expect($redis.exists?(RedisKey.stalled_blast_auto_resumed(blast.id))).to be(false)
        expect(InternalNotificationWorker).not_to have_received(:perform_async)
      end

      it "does not touch RUNNING, QUEUED, or RETRYING blasts" do
        running = stalled_blast
        queued_blast = stalled_blast(post: create(:installment))
        retrying = stalled_blast(post: create(:installment))
        stub_sidekiq(busy: [running.id], queued: [queued_blast.id], retrying: [retrying.id])

        described_class.new.perform

        expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
        expect(InternalNotificationWorker).not_to have_received(:perform_async)
      end
    end

    context "when the blast already finished delivering" do
      before { Feature.activate(:auto_resume_stalled_post_blasts) }
      after { Feature.deactivate(:auto_resume_stalled_post_blasts) }

      def fully_delivered_blast(**args)
        blast = stalled_blast(**args)
        $redis.set(RedisKey.blast_pending_recipients(blast.id), 0)
        blast
      end

      it "resumes a DEAD blast so the send job stamps it" do
        blast = fully_delivered_blast(requested_hours_ago: 6)
        stub_sidekiq(dead: [blast.id])

        described_class.new.perform

        expect(SendPostBlastEmailsJob).to have_received(:perform_async).with(blast.id)
        expect(@dead_jobs.fetch(blast.id)).to have_received(:delete)
        expect(InternalNotificationWorker).not_to have_received(:perform_async)
      end

      it "resumes past the window and after a previous auto-resume, since it cannot double-send" do
        blast = fully_delivered_blast(requested_hours_ago: 30)
        $redis.set(RedisKey.stalled_blast_auto_resumed(blast.id), Time.current.iso8601)
        stub_sidekiq

        described_class.new.perform

        expect(SendPostBlastEmailsJob).to have_received(:perform_async).with(blast.id)
        expect(InternalNotificationWorker).not_to have_received(:perform_async)
      end

      it "resumes an UNACCOUNTED non-opener resend, which the double-delivery hold would otherwise block" do
        blast = fully_delivered_blast(requested_hours_ago: 6)
        blast.update!(recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED)
        stub_sidekiq

        described_class.new.perform

        expect(SendPostBlastEmailsJob).to have_received(:perform_async).with(blast.id)
      end

      it "leaves the once-per-blast resume marker unspent" do
        blast = fully_delivered_blast(requested_hours_ago: 6)
        stub_sidekiq

        described_class.new.perform

        expect($redis.exists?(RedisKey.stalled_blast_auto_resumed(blast.id))).to be(false)
        expect($redis.exists?(RedisKey.stalled_blast_completion_resumed(blast.id))).to be(true)
      end

      it "resumes only once, even across runs" do
        blast = fully_delivered_blast(requested_hours_ago: 6)
        stub_sidekiq

        described_class.new.perform
        described_class.new.perform

        expect(SendPostBlastEmailsJob).to have_received(:perform_async).with(blast.id).once
      end

      it "skips a blast whose sender reappeared at action time" do
        blast = fully_delivered_blast(requested_hours_ago: 6)
        stub_sidekiq(busy: [blast.id])

        described_class.new.perform

        expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
        expect($redis.exists?(RedisKey.stalled_blast_completion_resumed(blast.id))).to be(false)
      end

      it "takes the ordinary resume route when recipients are still owed" do
        blast = stalled_blast(requested_hours_ago: 6)
        $redis.set(RedisKey.blast_pending_recipients(blast.id), 12)
        stub_sidekiq

        described_class.new.perform

        expect(SendPostBlastEmailsJob).to have_received(:perform_async).with(blast.id)
        expect($redis.exists?(RedisKey.stalled_blast_auto_resumed(blast.id))).to be(true)
        expect(InternalNotificationWorker).not_to have_received(:perform_async)
      end
    end

    context "when the flag is off" do
      it "reports a fully delivered blast without enqueueing anything" do
        blast = stalled_blast(requested_hours_ago: 6)
        $redis.set(RedisKey.blast_pending_recipients(blast.id), 0)
        stub_sidekiq

        described_class.new.perform

        expect(SendPostBlastEmailsJob).not_to have_received(:perform_async)
        expect($redis.exists?(RedisKey.stalled_blast_completion_resumed(blast.id))).to be(false)
        expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
          expect(message).to match(/blast #{blast.id}.*WOULD RESUME TO COMPLETE \(dry run/)
        end
      end

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

        expect(@dead_jobs.fetch(blast.id)).not_to have_received(:delete)
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
