# frozen_string_literal: true

class BackfillTaggingsCountOnTagsJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :low, lock: :until_executed

  def perform
    Onetime::BackfillTaggingsCountOnTags.process
  end
end
