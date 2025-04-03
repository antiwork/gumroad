# frozen_string_literal: true

class UpdateInMongoWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :mongo

  def perform(collection, conditions, doc)
    Mongoer.safe_update(collection, conditions, doc)
  end
end
