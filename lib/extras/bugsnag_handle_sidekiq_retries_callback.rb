# frozen_string_literal: true

BugsnagHandleSidekiqRetriesCallback = proc do |report|
  sidekiq_data = report.meta_data[:sidekiq]
  next if sidekiq_data.nil?
  msg = sidekiq_data[:msg]

  # When a worker does not have an explicit "retry" option configured, configured_retries => `true`.
  # We can't use this to determine whether this is the last attempt or not.
  configured_retries = msg["retry"]
  next unless configured_retries.is_a?(Integer)

  # retry_count is nil for the first attempt, then 0, 1, etc.
  retry_count = msg["retry_count"]

  # if retry_count is nil (first attempt) and retry is 0, this is the last attempt.
  last_attempt = retry_count.nil? && configured_retries == 0
  # if retry is equal to (zero indexed) retry_count, this is the last attempt.
  last_attempt |= retry_count.present? && configured_retries == retry_count + 1

  report.ignore! unless last_attempt
end
