# frozen_string_literal: true

# `sidekiq-pro` is now only autoloaded in staging/production due to the Gemfile
# group. This ensures `sidekiq-pro` is correctly loaded in all environments
# when available.
begin
  require "sidekiq-pro"
rescue LoadError
  warn "sidekiq-pro is not installed"
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

  SidekiqUniqueJobs::Server.configure(config)
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
