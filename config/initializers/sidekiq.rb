# frozen_string_literal: true

# `sidekiq-pro` is now only autoloaded in staging/production due to the Gemfile
# group. This ensures `sidekiq-pro` is correctly loaded in all environments
# when available.
begin
  require "sidekiq-pro"
rescue LoadError
  warn "sidekiq-pro is not installed"
end

require Rails.root.join("lib", "extras", "sidekiq_makara_reset_context_middleware")

Sidekiq.configure_server do |config|
  config.redis = { url: "redis://#{ENV["SIDEKIQ_REDIS_HOST"]}" }

  if defined?(Sidekiq::Pro)
    # https://github.com/mperham/sidekiq/wiki/Reliability#using-super_fetch
    config.super_fetch!

    # https://github.com/mperham/sidekiq/wiki/Reliability#scheduler
    config.reliable_scheduler!
  end

  # Cleanup Dead Locks
  # https://github.com/mhenrixon/sidekiq-unique-jobs/tree/ec69ac93afccd56cd424e2a9738e5ed478d941b2#cleanup-dead-locks
  #
  # Read BOTH digest keys: sidekiq-unique-jobs v7+ writes `lock_digest`
  # (SidekiqUniqueJobs::LOCK_DIGEST) while `unique_digest` is the pre-v7 name. Reading only the
  # old key made this handler a silent no-op on v8 — a job that died left its `until_executed`
  # lock in Redis forever, and because these locks carry no `lock_ttl` by default, every later
  # enqueue was dropped as a duplicate. That is how abandoned-cart emails stopped platform-wide
  # for 6 days (gumroad-private#1576); it applies to every `until_executed` job, not just that one.
  config.death_handlers << ->(job, _ex) do
    digest = job[SidekiqUniqueJobs::LOCK_DIGEST] || job["unique_digest"]
    SidekiqUniqueJobs::Digests.new.delete_by_digest(digest) if digest
  end

  config.client_middleware do |chain|
    chain.add SidekiqUniqueJobs::Middleware::Client
  end

  config.server_middleware do |chain|
    chain.add SidekiqMakaraResetContextMiddleware
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
