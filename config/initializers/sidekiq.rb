# frozen_string_literal: true

# `sidekiq-pro` is now only autoloaded in staging/production due to the Gemfile
# group. This ensures `sidekiq-pro` is correctly loaded in all environments
# when available.
begin
  require "sidekiq-pro"
rescue LoadError
  warn "sidekiq-pro is not installed"
end

# Partner imports run on their own threads inside the `long` process, so a migration wave cannot
# hold back the buyer-facing PDF stamping that shares the `long` queue's nodes. Each import holds
# its thread for hours and moves up to gigabytes, so the thread count also caps the node's load.
module PartnerImportCapsule
  QUEUE = "partner_import"
  CONCURRENCY = 3

  # Every job thread needs a database connection, so the capsule takes only the connections that the
  # default capsule leaves free, less one spare, as database.yml asks. It never starves the jobs on
  # `long`, whatever DB_POOL_SIZE is.
  def self.configure(config, pool_size: ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).filter_map(&:max_connections).min)
    return unless config.queues.include?("long")

    concurrency = [CONCURRENCY, pool_size.to_i - config.default_capsule.concurrency - 1].min
    if concurrency < 1
      # Raising would stop the `long` process and its buyer-facing jobs, so report it instead. App
      # classes load after this initializer, so the report waits for startup.
      config.on(:startup) { ErrorNotifier.notify("No free database connections for the #{QUEUE} capsule, so nothing processes #{QUEUE}. Raise DB_POOL_SIZE.") }
      return
    end

    config.capsule(QUEUE) do |capsule|
      capsule.concurrency = concurrency
      capsule.queues = [QUEUE]
    end
  end
end

Sidekiq.configure_server do |config|
  config.redis = { url: "redis://#{ENV["SIDEKIQ_REDIS_HOST"]}" }

  if defined?(Sidekiq::Pro)
    # https://github.com/mperham/sidekiq/wiki/Reliability#using-super_fetch
    config.super_fetch!

    # https://github.com/mperham/sidekiq/wiki/Reliability#scheduler
    config.reliable_scheduler!
  end

  config.client_middleware do |chain|
    chain.add SidekiqUniqueJobs::Middleware::Client
  end

  config.server_middleware do |chain|
    chain.add SidekiqUniqueJobs::Middleware::Server
  end

  # The number of jobs that are stored after retries are exhausted.
  config[:dead_max_jobs] = 20_000_000

  # SidekiqUtility drains every process on an instance by this label.
  config[:labels] << "instance:#{ENV["EC2_INSTANCE_ID"]}" if ENV["EC2_INSTANCE_ID"].present?

  SidekiqUniqueJobs::Server.configure(config)

  PartnerImportCapsule.configure(config)
end

Sidekiq.configure_client do |config|
  config.redis = { url: "redis://#{ENV["SIDEKIQ_REDIS_HOST"]}" }

  config.client_middleware do |chain|
    chain.add SidekiqUniqueJobs::Middleware::Client
  end
end

SidekiqUniqueJobs.configure do |config|
  config.enabled = !Rails.env.test?
end

# https://github.com/mperham/sidekiq/wiki/Pro-Reliability-Client
Sidekiq::Client.reliable_push! if defined?(Sidekiq::Pro) && !Rails.env.test?

# Store exception backtrace
# https://github.com/mperham/sidekiq/wiki/Error-Handling#backtrace-logging
Sidekiq.default_job_options = { "backtrace" => true, "retry" => 25 }
