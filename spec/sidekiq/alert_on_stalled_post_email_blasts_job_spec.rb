# frozen_string_literal: true

require "spec_helper"

describe AlertOnStalledPostEmailBlastsJob do
  let(:post) { create(:installment) }

  def stalled_blast(requested_hours_ago: 6, post: self.post, delivery_count: 0, started: true)
    requested_at = requested_hours_ago.hours.ago
    create(:post_email_blast, post:, requested_at:, started_at: started ? requested_at + 1.minute : nil,
                              completed_at: nil, delivery_count:)
  end

  def stub_sidekiq(dead: [], retrying: [], busy: [], queued: [])
    dead_set = instance_double(Sidekiq::DeadSet)
    allow(Sidekiq::DeadSet).to receive(:new).and_return(dead_set)
    allow(dead_set).to receive(:scan) do |_match, &block|
      dead.each { |id| block.call(fake_sidekiq_job(id)) }
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
    instance_double(Sidekiq::SortedEntry, klass: "SendPostBlastEmailsJob", args: [blast_id])
  end

  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
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
end
