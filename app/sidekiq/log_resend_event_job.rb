# frozen_string_literal: true

# No-op stub so payloads already in the low queue / retry set drain cleanly
# after EmailEvent's removal. Delete once a post-removal deploy has aged out
# the retry window.
class LogResendEventJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :low

  def perform(*)
  end
end
