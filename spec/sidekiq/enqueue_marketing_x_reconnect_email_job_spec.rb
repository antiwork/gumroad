# frozen_string_literal: true

require "spec_helper"
require "sidekiq/capsule"
require "sidekiq/job_retry"
require "sidekiq/scheduled"
require "timeout"

describe EnqueueMarketingXReconnectEmailJob do
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
    @seller = create(:user, twitter_oauth_token: nil, twitter_oauth_secret: nil)
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

  def perform_dispatch_with_retry
    job = described_class.jobs.first
    retry_handler = Sidekiq::JobRetry.new(Sidekiq.default_configuration.default_capsule)
    expect do
      retry_handler.local(described_class.new, Sidekiq.dump_json(job), "low") { described_class.perform_one }
    end.to raise_error(Sidekiq::JobRetry::Handled)
    job
  end

  def retry_dispatch
    travel_to 1.hour.from_now do
      Sidekiq::Scheduled::Enq.new(Sidekiq.default_configuration).enqueue_jobs(["retry"])
    end
    described_class.drain
  end

  [:channel, :backlog].each do |producer|
    it "recovers #{producer} work committed after the last query of a cancelled legacy delivery" do
      @actions.last.update!(error_code: nil)
      SendMarketingXReconnectEmailJob.perform_async(@seller.id)
      legacy_job = SendMarketingXReconnectEmailJob.jobs.sole
      expect(legacy_job).not_to have_key("on_conflict")
      key = SidekiqUniqueJobs::Key.new(legacy_job["lock_digest"])
      allow(CreatorMailer).to receive(:marketing_x_reconnect).and_wrap_original do |original, **arguments|
        @actions.first.cancel! if arguments[:marketing_action_id] == @actions.first.id
        original.call(**arguments)
      end
      dispatch_job = nil
      allow_any_instance_of(SendMarketingXReconnectEmailJob).to receive(:perform).and_wrap_original do |original, *args|
        result = original.call(*args)
        if original.receiver.jid == legacy_job["jid"]
          expect(Sidekiq.redis { |redis| redis.hget(key.locked, legacy_job["jid"]) }).to be_present
          expect(@actions.first.reload).to be_cancelled
          expect(@actions.last.reload.error_code).to be_nil
          if producer == :channel
            Marketing::Channels::X.new(@actions.last).call
          else
            @actions.last.update!(error_code: Marketing::Action::X_WRITE_PERMISSION_MISSING)
            Onetime::NotifyMarketingXReconnectBacklog.process
          end
          dispatch_job = perform_dispatch_with_retry if described_class.jobs.any?
        end
        result
      end

      SendMarketingXReconnectEmailJob.perform_one

      expect(Sidekiq.redis { |redis| redis.exists(key.locked) }).to eq(0)
      expect(ActionMailer::Base.deliveries).to be_empty
      expect(@actions.last.reload.reconnect_notified_at).to be_nil
      retries = Sidekiq.redis { |redis| redis.zrange("retry", 0, -1) }.map { Sidekiq.load_json(_1) }
      expect(retries.size).to eq(1)
      expect(retries.sole).to include("class" => described_class.name, "jid" => dispatch_job["jid"],
                                      "args" => [@seller.id], "retry_count" => 0, "retry" => 25,
                                      "error_class" => "SidekiqUniqueJobs::Conflict")

      retry_dispatch
      expect { SendMarketingXReconnectEmailJob.drain }.to change { ActionMailer::Base.deliveries.size }.by(1)
      expect(ActionMailer::Base.deliveries.last.body.encoded).to include("/products/#{@products.last.unique_permalink}/edit/share")
      expect(@actions.first.reload.reconnect_notified_at).to be_nil
      expect(@actions.last.reload.reconnect_notified_at).to be_present
      expect(described_class.jobs + SendMarketingXReconnectEmailJob.jobs).to be_empty
      expect(Sidekiq.redis { |redis| redis.zcard("retry") + redis.zcard("schedule") }).to eq(0)
    end
  end

  it "keeps the legacy base lock and retries dispatch while an old worker delivers" do
    current_options = SendMarketingXReconnectEmailJob.get_sidekiq_options.deep_dup
    legacy_options = current_options.except("on_conflict", "lock_timeout").merge("lock" => "until_executed")
    allow(SendMarketingXReconnectEmailJob).to receive(:get_sidekiq_options).and_return(legacy_options)
    SendMarketingXReconnectEmailJob.perform_async(@seller.id)
    legacy_job = SendMarketingXReconnectEmailJob.jobs.sole
    expect(legacy_job).not_to have_key("on_conflict")
    key = SidekiqUniqueJobs::Key.new(legacy_job["lock_digest"])
    delivering = Queue.new
    proceed = Queue.new
    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_wrap_original do |original, mail|
      delivering << true
      Timeout.timeout(10) { proceed.pop }
      original.call(mail)
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { SendMarketingXReconnectEmailJob.perform_one }
    end
    Timeout.timeout(10) { delivering.pop }
    allow(SendMarketingXReconnectEmailJob).to receive(:get_sidekiq_options).and_return(current_options)
    expect(Sidekiq.redis { |redis| redis.pttl(key.locked) }).to eq(-1)
    described_class.perform_async(@seller.id)
    perform_dispatch_with_retry
    expect(SendMarketingXReconnectEmailJob.jobs).to be_empty
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(Sidekiq.redis { |redis| redis.hget(key.locked, legacy_job["jid"]) }).to be_present
    proceed << true
    expect(worker.join(10)).to eq(worker)
    worker.value

    retry_dispatch
    expect(SendMarketingXReconnectEmailJob.jobs.sole["lock_digest"]).to eq(legacy_job["lock_digest"])
    expect { SendMarketingXReconnectEmailJob.drain }.not_to change { ActionMailer::Base.deliveries.size }
    expect(ActionMailer::Base.deliveries.size).to eq(1)
  ensure
    proceed << true if proceed
    worker&.join(15)
  end
end
