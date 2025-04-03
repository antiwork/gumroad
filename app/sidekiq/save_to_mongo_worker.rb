# frozen_string_literal: true

class SaveToMongoWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :mongo

  def perform(collection, doc)
    Mongoer.safe_write(collection, doc)
  end
end
