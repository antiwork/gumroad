# frozen_string_literal: true

unless ENV["DISABLE_RACK_TIMEOUT"] == "1"
  # A web request holds one of PUMA_WORKER_PROCESSES * RAILS_MAX_THREADS slots per host
  # (6 * 2 = 12 in production), so the service timeout is the ceiling on how long a single
  # request can occupy 1/12th of a host. At 120s a dozen slow requests could pin a whole host
  # for two minutes, which is the mechanism behind the 2026-07-31 capacity collapse: held
  # workers slow everything, the ALB health check queues behind them, and slow-but-alive hosts
  # get ejected.
  #
  # 15s is the budget for anything a buyer waits on. Work that legitimately runs longer belongs
  # in Sidekiq, not in a web worker.
  service_timeout = (ENV["RACK_TIMEOUT_SERVICE_TIMEOUT"] || 15).to_i

  Rails.application.config.middleware.insert_before(
    Rack::Runtime,
    Rack::Timeout,
    service_timeout:,
    wait_overtime: 24.hours.to_i,
    wait_timeout: false
  )

  Rack::Timeout::Logger.disable unless ENV["ENABLE_RACK_TIMEOUT_LOGS"] == "1"
end
