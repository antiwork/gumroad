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
      # Symmetric with unblock!: a block added while a concurrent removal is mid-flight would
      # otherwise go unenforced in Radar until tomorrow's sync, because the removal's own final
      # check can only see the row before it commits. Read the type off the record, not the
      # argument — callers pass it as a symbol too, and syncs? matches the persisted string.
      Radar::AddValueListItemJob.perform_async(record.id) if Radar::ValueListSyncService.syncs?(record.object_type)
    end
  end

  # Radar, not this row, enforces email/card blocks, so a MySQL-only unblock stays blocked until
  # the daily sync (gumroad-private#1647). Enqueued unconditionally: re-running unblock! is the
  # only repair for an item stranded in Radar, since a no-op update! never moves updated_at back
  # into the sync's window.
  def unblock!
    update!(blocked_at: nil, expires_at: nil)
    Radar::RemoveValueListItemJob.perform_async(id) if Radar::ValueListSyncService.syncs?(object_type)
  end
end
