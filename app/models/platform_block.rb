# frozen_string_literal: true

class PlatformBlock < ApplicationRecord
  TYPES = {
    ip_address: "ip_address",
    browser_guid: "browser_guid",
    email: "email",
    email_domain: "email_domain",
    charge_processor_fingerprint: "charge_processor_fingerprint",
    product: "product",
  }.freeze

  # Block the IP for 6 months so that if the IP gets reallocated it can be used again.
  # Also prevents the list of blocked IPs from growing indefinitely.
  IP_ADDRESS_BLOCKING_DURATION_IN_MONTHS = 6

  TYPES.each_value do |object_type|
    scope object_type, -> { where(object_type:) }
    define_method("#{object_type}?") { self.object_type == object_type }
  end

  validates :object_type, inclusion: { in: TYPES.values }

  scope :active, -> { where.not(blocked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def self.add!(object_type:, object_value:, by: nil, expires_in: nil)
    if object_type.to_s == TYPES[:ip_address] && expires_in.blank?
      raise ArgumentError, "expires_in is required when blocking an ip_address"
    end

    now = Time.current
    create_or_find_by!(object_type:, object_value:).tap do |record|
      record.update!(
        blocked_at: now,
        blocked_by: by,
        expires_at: expires_in.present? ? now + expires_in : nil,
      )
    end
  end

  def unblock!
    update!(blocked_at: nil, expires_at: nil)
  end
end
