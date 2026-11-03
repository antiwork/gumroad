# frozen_string_literal: true

require "spec_helper"
require "sidekiq/capsule"

describe PartnerImportCapsule do
  def config_for(queues, concurrency: 10)
    Sidekiq::Config.new.tap do |config|
      config.queues = queues
      config.default_capsule.concurrency = concurrency
    end
  end

  it "gives partner imports their own threads in the long-running process" do
    config = config_for(%w[long])

    described_class.configure(config, pool_size: 15)

    expect(config.capsules.fetch("partner_import")).to have_attributes(concurrency: 3, queues: %w[partner_import])
    expect(config.capsules.fetch("default").queues).to eq(%w[long])
  end

  it "takes only the database connections that the default capsule leaves free, less one spare" do
    config = config_for(%w[long])

    described_class.configure(config, pool_size: 12)

    expect(config.capsules.fetch("partner_import").concurrency).to eq(1)
  end

  it "does not start without a free database connection, and reports it at startup" do
    config = config_for(%w[long])
    allow(ErrorNotifier).to receive(:notify)

    described_class.configure(config, pool_size: 11)
    config[:lifecycle_events][:startup].each(&:call)

    expect(config.capsules.keys).to eq(%w[default])
    expect(ErrorNotifier).to have_received(:notify).with(/Raise DB_POOL_SIZE/)
  end

  it "leaves the other worker processes alone" do
    config = config_for(%w[critical default low exports])

    described_class.configure(config, pool_size: 15)

    expect(config.capsules.keys).to eq(%w[default])
  end

  it "sizes itself from the database pool that the app is configured with" do
    config = config_for(%w[long], concurrency: 1)
    expected = [described_class::CONCURRENCY, ActiveRecord::Base.connection_pool.db_config.max_connections - 2].min

    described_class.configure(config)

    expect(config.capsules.fetch("partner_import").concurrency).to eq(expected)
  end

  it "attaches in the worker process that the long-running nodes start" do
    worker_script = Rails.root.join("docker/web/sidekiq_worker.sh").read
    long_worker_queues = worker_script[/if \[ "\$1" = "long" \]; then\s+bundle exec sidekiq(.*?)\n\s*else/m, 1].scan(/-q (\S+)/).flatten
    config = config_for(long_worker_queues)

    described_class.configure(config, pool_size: 15)

    expect(config.capsules).to include("partner_import")
  end

  it "is the queue that the import job uses" do
    expect(PartnerMigrationImportJob.get_sidekiq_options["queue"].to_s).to eq(described_class::QUEUE)
  end
end
