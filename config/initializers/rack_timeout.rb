# frozen_string_literal: true

unless ENV["DISABLE_RACK_TIMEOUT"] == "1"
  Rails.application.config.middleware.insert_before(
    Rack::Runtime,
    Rack::Timeout,
    service_timeout: 120,
    wait_overtime: 24.hours.to_i,
    wait_timeout: false
  )

  Rack::Timeout::Logger.disable unless ENV["ENABLE_RACK_TIMEOUT_LOGS"] == "1"
end
