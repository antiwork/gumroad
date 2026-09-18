# frozen_string_literal: true

require "spec_helper"
require "sidekiq/capsule"
require "sidekiq/job_retry"
require "sidekiq/scheduled"
require "timeout"

describe SendMarketingXReconnectEmailJob, "with uniqueness enabled" do
  self.use_transactional_tests = false

  around do |example|
    SidekiqUniqueJobs.use_config(enabled: true) do
      Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
      example.run
    ensure
      Sidekiq::Testing.server_middleware { |chain| chain.remove SidekiqUniqueJobs::Middleware::Server }
    end
  end

  before do
    @seller = create(:user)
    @products = Array.new(2) { create(:product, user: @seller) }
    @actions = @products.map do |product|
      create(:marketing_action, user: @seller, link: product, status: "approved",
                                error_code: Marketing::Action::X_WRITE_PERMISSION_MISSING)
    end
  end

  after do
    Marketing::Action.where(user_id: @seller.id).delete_all
    @products.each(&:destroy!)
    @seller.destroy!
  end

  it "deduplicates queued and in-flight seller enqueues and covers a product that fails during delivery" do
    @actions.last.update!(error_code: nil)
    Onetime::NotifyMarketingXReconnectBacklog.process
    EnqueueMarketingXReconnectEmailJob.drain
    expect(described_class.jobs.sole["args"]).to eq([@seller.id])
    expect(described_class.perform_async(@seller.id)).to be_nil
    job = described_class.jobs.sole
    key = SidekiqUniqueJobs::Key.new(job["lock_digest"])
    expect(Sidekiq.redis { |redis| redis.pttl(key.locked) }).to eq(-1)

    delivering = Queue.new
    proceed = Queue.new
    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_wrap_original do |original, mail|
      delivering << true
      Timeout.timeout(10) { proceed.pop }
      original.call(mail)
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { described_class.perform_one }
    end
    Timeout.timeout(10) { delivering.pop }
    @actions.last.update!(error_code: Marketing::Action::X_WRITE_PERMISSION_MISSING)
    expect(described_class.perform_async(@seller.id)).to be_nil
    Onetime::NotifyMarketingXReconnectBacklog.process
    expect(described_class.jobs).to be_empty
    expect(@actions.map { _1.reload.reconnect_notified_at }).to eq([nil, nil])
    proceed << true
    expect(worker.join(10)).to eq(worker)
    worker.value

    expect(ActionMailer::Base.deliveries.size).to eq(1)
    expect(@actions.map { _1.reload.reconnect_notified_at }).to all(be_present)
    expect(Sidekiq.redis { |redis| redis.exists(key.locked) }).to eq(0)
    EnqueueMarketingXReconnectEmailJob.drain
    expect(described_class.perform_async(@seller.id)).to be_nil
    expect { described_class.drain }.not_to change { ActionMailer::Base.deliveries.size }
  ensure
    proceed << true if proceed
    worker&.join(15)
  end

  it "holds no transaction or row locks during delivery and excludes a cancelled sibling" do
    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_wrap_original do |original, mail|
      expect(ActiveRecord::Base.connection.transaction_open?).to eq(false)
      writer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          User.find(@seller.id).with_lock do
            sibling = Marketing::Action.find(@actions.last.id)
            sibling.with_lock { sibling.cancel! }
          end
        end
      end
      begin
        expect(writer.join(5)).to eq(writer)
        writer.value
      ensure
        writer.kill if writer.alive?
        writer.join
      end
      original.call(mail)
    end

    described_class.perform_async(@seller.id)
    expect { described_class.drain }.to change { ActionMailer::Base.deliveries.size }.by(1)
    expect(@actions.first.reload.reconnect_notified_at).to be_present
    expect(@actions.last.reload).to be_cancelled
    expect(@actions.last.reconnect_notified_at).to be_nil
  end

  it "falls through to a sibling when the selected action is cancelled before mailer evaluation" do
    allow(CreatorMailer).to receive(:marketing_x_reconnect).and_wrap_original do |original, **arguments|
      @actions.first.cancel! if arguments[:marketing_action_id] == @actions.first.id
      original.call(**arguments)
    end

    described_class.perform_async(@seller.id)
    expect { described_class.drain }.to change { ActionMailer::Base.deliveries.size }.by(1)
    expect(ActionMailer::Base.deliveries.last.body.encoded).to include("/products/#{@products.last.unique_permalink}/edit/share")
    expect(@actions.first.reload.reconnect_notified_at).to be_nil
    expect(@actions.last.reload.reconnect_notified_at).to be_present
  end

  it "releases the lock after SMTP failure and delivers through the scheduled retry path" do
    described_class.perform_async(@seller.id)
    job = described_class.jobs.sole
    key = SidekiqUniqueJobs::Key.new(job["lock_digest"])
    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_raise(Net::ReadTimeout)
    retry_handler = Sidekiq::JobRetry.new(Sidekiq.default_configuration.default_capsule)

    expect do
      retry_handler.local(described_class.new, Sidekiq.dump_json(job), "low") { described_class.perform_one }
    end.to raise_error(Sidekiq::JobRetry::Handled)

    expect(@actions.map { _1.reload.reconnect_notified_at }).to eq([nil, nil])
    expect(Sidekiq.redis { |redis| redis.exists(key.locked) }).to eq(0)
    retried = Sidekiq.redis { |redis| redis.zrange("retry", 0, -1) }.map { Sidekiq.load_json(_1) }.sole
    expect(retried).to include("jid" => job["jid"], "args" => [@seller.id], "retry_count" => 0, "error_class" => "Net::ReadTimeout")

    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_call_original
    travel_to 1.hour.from_now do
      Sidekiq::Scheduled::Enq.new(Sidekiq.default_configuration).enqueue_jobs(["retry"])
    end
    expect(described_class.jobs.sole["jid"]).to eq(job["jid"])
    expect(described_class.perform_async(@seller.id)).to be_nil
    expect { described_class.drain }.to change { ActionMailer::Base.deliveries.size }.by(1)
    expect(@actions.map { _1.reload.reconnect_notified_at }).to all(be_present)
  end

  it "retries after cancellation when a newly eligible product's enqueue was suppressed" do
    @actions.last.update!(error_code: nil)
    described_class.perform_async(@seller.id)
    job = described_class.jobs.sole
    key = SidekiqUniqueJobs::Key.new(job["lock_digest"])
    allow(CreatorMailer).to receive(:marketing_x_reconnect).and_wrap_original do |original, **arguments|
      if arguments[:marketing_action_id] == @actions.first.id
        expect(Sidekiq.redis { |redis| redis.hget(key.locked, job["jid"]) }).to be_present
        @actions.first.cancel!
        @actions.last.update!(error_code: Marketing::Action::X_WRITE_PERMISSION_MISSING)
        expect(described_class.perform_async(@seller.id)).to be_nil
      end
      original.call(**arguments)
    end
    retry_handler = Sidekiq::JobRetry.new(Sidekiq.default_configuration.default_capsule)

    expect do
      retry_handler.local(described_class.new, Sidekiq.dump_json(job), "low") { described_class.perform_one }
    end.to raise_error(Sidekiq::JobRetry::Handled)

    expect(Sidekiq.redis { |redis| redis.exists(key.locked) }).to eq(0)
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(@actions.last.reload.reconnect_notified_at).to be_nil
    expect(described_class.jobs).to be_empty
    retried = Sidekiq.redis { |redis| redis.zrange("retry", 0, -1) }.map { Sidekiq.load_json(_1) }.sole
    expect(retried).to include("jid" => job["jid"], "args" => [@seller.id], "retry_count" => 0)

    travel_to 1.hour.from_now do
      Sidekiq::Scheduled::Enq.new(Sidekiq.default_configuration).enqueue_jobs(["retry"])
    end
    expect(described_class.jobs.sole["jid"]).to eq(job["jid"])
    expect { described_class.drain }.to change { ActionMailer::Base.deliveries.size }.by(1)
    expect(ActionMailer::Base.deliveries.last.body.encoded).to include("/products/#{@products.last.unique_permalink}/edit/share")
    expect(@actions.first.reload.reconnect_notified_at).to be_nil
    expect(@actions.last.reload.reconnect_notified_at).to be_present
  end

  it "finishes without retry when all candidates are cancelled and no new work appeared" do
    allow(CreatorMailer).to receive(:marketing_x_reconnect).and_wrap_original do |original, **arguments|
      @actions.each { _1.cancel! } if arguments[:marketing_action_id] == @actions.first.id
      original.call(**arguments)
    end

    described_class.perform_async(@seller.id)
    expect { described_class.drain }.not_to change { ActionMailer::Base.deliveries.size }
    expect(@actions.map { _1.reload.reconnect_notified_at }).to eq([nil, nil])
    expect(described_class.jobs).to be_empty
  end
end
