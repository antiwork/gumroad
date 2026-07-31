# frozen_string_literal: true

require Rails.root.join("lib", "extras", "budgeted_request_timeout")

unless ENV["DISABLE_RACK_TIMEOUT"] == "1"
  # A web request holds one of PUMA_WORKER_PROCESSES * RAILS_MAX_THREADS slots per host
  # (6 * 2 = 12 in production), so the budget is the ceiling on how long one request can occupy
  # 1/12th of a host. At 120s a dozen slow requests could pin a whole host for two minutes,
  # which is the mechanism behind the 2026-07-31 capacity collapse: held workers slow
  # everything, the ALB health check queues behind them, and slow-but-alive hosts get ejected.
  #
  # Both budgets and their env overrides live in BudgetedRequestTimeout::Budget; checkout keeps
  # the old 120s ceiling. Work that legitimately runs long belongs in Sidekiq, not a web worker.
  Rails.application.config.middleware.insert_before(
    Rack::Runtime,
    BudgetedRequestTimeout,
    wait_overtime: 24.hours.to_i,
    wait_timeout: false
  )

  Rack::Timeout::Logger.disable unless ENV["ENABLE_RACK_TIMEOUT_LOGS"] == "1"
end
