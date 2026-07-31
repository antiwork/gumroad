# frozen_string_literal: true

unless ENV["DISABLE_RACK_TIMEOUT"] == "1"
  # A web request holds one of PUMA_WORKER_PROCESSES * RAILS_MAX_THREADS slots per host
  # (6 * 2 = 12 in production), so this is the ceiling on how long one request can occupy
  # 1/12th of a host. At 120s a dozen slow requests could pin a whole host for two minutes,
  # which is the mechanism behind the 2026-07-31 capacity collapse: held workers slow
  # everything, the ALB health check queues behind them, and slow-but-alive hosts get ejected.
  #
  # 15s is the budget for anything a buyer waits on. Work that legitimately runs longer belongs
  # in Sidekiq, not in a web worker.
  default_service_timeout = 15

  # Deliberately strict: rack-timeout treats 0 as `false` and disables the timeout outright, and
  # a bare `.to_i` turns "" / "abc" / a stray newline into exactly that. Silently running with no
  # request ceiling is worse than the 120s this replaced, so anything unparseable falls back to
  # the default rather than to "unlimited".
  configured = ENV["RACK_TIMEOUT_SERVICE_TIMEOUT"]
  service_timeout =
    if configured.present? && configured.to_s.match?(/\A\d+\z/) && configured.to_i.positive?
      configured.to_i
    else
      Rails.logger.warn("Ignoring invalid RACK_TIMEOUT_SERVICE_TIMEOUT=#{configured.inspect}") if configured.present?
      default_service_timeout
    end

  Rails.application.config.middleware.insert_before(
    Rack::Runtime,
    Rack::Timeout,
    service_timeout:,
    wait_overtime: 24.hours.to_i,
    wait_timeout: false
  )

  Rack::Timeout::Logger.disable unless ENV["ENABLE_RACK_TIMEOUT_LOGS"] == "1"
end
