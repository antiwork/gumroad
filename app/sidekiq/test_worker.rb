# frozen_string_literal: true

class TestWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(timeout)
    h = SecureRandom.hex(4)
    Rails.logger.info "#{h} sidekiq test begin timeout: #{timeout}"
    sleep timeout.to_i
    Rails.logger.info "#{h} sidekiq test end timeout: #{timeout}"
  end
end
