# frozen_string_literal: true

require "spec_helper"

describe AlertOnStalledPostEmailBlastsJob do
  let(:post) { create(:installment) }

  def stalled_blast(started_hours_ago: 6, post: self.post)
    create(:post_email_blast, post:, started_at: started_hours_ago.hours.ago, completed_at: nil)
  end

  def stub_sidekiq(dead: [], retrying: [], busy: [])
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

  it "reports a stalled blast with its dead-set disposition and sent count" do
    blast = stalled_blast
    create(:sent_post_email, post:, email: "a@example.com")
    create(:sent_post_email, post:, email: "b@example.com")
    stub_sidekiq(dead: [blast.id])

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |room, subject, message|
      expect(room).to eq("payments")
      expect(subject).to eq("Stalled post email blasts")
      expect(message).to include("1 email blast started sending")
      expect(message).to include("blast #{blast.id}")
      expect(message).to include("2 sent, DEAD")
    end
  end

  it "stays silent when every started blast completed or is under the stall threshold" do
    create(:post_email_blast, post:, started_at: 6.hours.ago, completed_at: 5.hours.ago)
    create(:post_email_blast, post:, started_at: 1.hour.ago, completed_at: nil)
    stub_sidekiq

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "ignores stalls older than the lookback so historical rows do not bury new ones" do
    stalled_blast(started_hours_ago: 15 * 24)
    stub_sidekiq

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "distinguishes running, retrying and unaccounted blasts" do
    running = stalled_blast
    retrying = stalled_blast(post: create(:installment))
    lost = stalled_blast(post: create(:installment))
    stub_sidekiq(busy: [running.id], retrying: [retrying.id])

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to match(/blast #{running.id}.*RUNNING/)
      expect(message).to match(/blast #{retrying.id}.*RETRYING/)
      expect(message).to match(/blast #{lost.id}.*UNACCOUNTED/)
    end
  end
end
