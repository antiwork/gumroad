# frozen_string_literal: true

class PlatformBlock < ApplicationRecord
  # Block the IP for 6 months so that if the IP gets reallocated can be used again
  # Also prevents the list of blocked IPs to grow indefinitely
  IP_ADDRESS_BLOCKING_DURATION_IN_MONTHS = 6

  BLOCKED_OBJECT_TYPES.each_value do |object_type|
    scope object_type, -> { where(object_type:) }
    define_method("#{object_type}?") { self.object_type == object_type }
  end

  validates :object_type, inclusion: { in: BLOCKED_OBJECT_TYPES.values }
  validates :expires_at, presence: { if: %i[ip_address? blocked_at?] }

  scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  class << self
    def add!(object_type:, object_value:, by: nil, expires_in: nil)
      now = Time.current
      create_or_find_by!(object_type:, object_value:).tap do |record|
        record.update!(
          blocked_at: now,
          blocked_by: by,
          expires_at: expires_in.present? ? now + expires_in : nil,
        )
      end
    end

    def find_object(object_value)
      find_by(object_value:)
    end

    def find_active_object(object_value)
      active.find_object(object_value)
    end

    def find_objects(object_values)
      where(object_value: object_values)
    end

    def find_active_objects(object_values)
      active.find_objects(object_values)
    end
  end

  def blocked?
    expires_at.nil? || expires_at > Time.current
  end
end
