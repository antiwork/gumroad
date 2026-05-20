# frozen_string_literal: true

class BlockObjectWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(object_type, identifier, author_id, expires_in = nil)
    PlatformBlock.add!(
      object_type: PlatformBlock::TYPES[object_type.to_sym],
      object_value: identifier,
      by: author_id,
      expires_in:,
    )
  end
end
