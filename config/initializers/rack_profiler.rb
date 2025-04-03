# frozen_string_literal: true

if ENV["RACK_MINI_PROFILER_ENABLED"] == "1"
  require "rack-mini-profiler"

  # initialization is skipped so trigger it
  Rack::MiniProfilerRails.initialize!(Rails.application)
end
