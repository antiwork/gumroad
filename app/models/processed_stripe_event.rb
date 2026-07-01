# frozen_string_literal: true

class ProcessedStripeEvent < ApplicationRecord
  validates :event_id, presence: true

  def self.processed?(event_id)
    exists?(event_id:)
  end

  def self.record!(event_id, event_type: nil)
    create!(event_id:, event_type:)
  rescue ActiveRecord::RecordNotUnique
    # Concurrent delivery of the same event already recorded it; the unique index makes this a no-op.
  end
end
