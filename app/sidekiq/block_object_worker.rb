# frozen_string_literal: true

class BlockObjectWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(object_type, identifier, author_id, expires_in = nil)
    now = Time.current
    record = PlatformBlock.create_or_find_by!(object_type: BLOCKED_OBJECT_TYPES[object_type.to_sym], object_value: identifier)
    record.update!(
      blocked_at: now,
      blocked_by: author_id,
      expires_at: expires_in.present? ? now + expires_in : nil
    )
  end
end
