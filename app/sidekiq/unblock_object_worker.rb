# frozen_string_literal: true

class UnblockObjectWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(object_value)
    PlatformBlock.where(object_value:).find_each(&:unblock!)
  end
end
