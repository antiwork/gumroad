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

  # Symmetric with unblock!: a block added while a concurrent removal is mid-flight would
  # otherwise go unenforced in Radar until tomorrow's sync. Runs after commit because callers
  # hold open transactions (Charge#refund_for_fraud_and_block_buyer! reaches add! inside a
  # with_lock) and the job's first act is to reload the row — enqueued in-transaction it can
  # dequeue before the commit, see blocked_at still nil, and no-op. add! always writes a fresh
  # blocked_at, so re-running it re-enqueues, mirroring unblock!'s repair property.
  after_commit :enqueue_radar_add, on: [:create, :update], if: -> { saved_change_to_blocked_at? && blocked_at.present? }

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

  # Radar, not this row, enforces email/card blocks, so a MySQL-only unblock stays blocked until
  # the daily sync (gumroad-private#1647). Enqueued unconditionally (not via an after_commit
  # attribute-change callback like enqueue_radar_add): re-running unblock! on an already-nil row is
  # the only repair for an item stranded in Radar, and a no-op update! fires no saved_change to hang
  # a callback on. Deferred with AfterCommitEverywhere because a caller can hold this inside its own
  # wrapping transaction (Risk::StrandedBuyerRecoveryService#clear!) — enqueued immediately, the job
  # could reload the still-active pre-commit row and no-op, stranding the Radar entry.
  def unblock!
    update!(blocked_at: nil, expires_at: nil)
    return unless Radar::ValueListSyncService.syncs?(object_type)

    AfterCommitEverywhere.after_commit { Radar::RemoveValueListItemJob.perform_async(id) }
  end

  private
    # syncs? matches the persisted string form of object_type, which also covers the callers
    # that pass add! a symbol.
    def enqueue_radar_add
      Radar::AddValueListItemJob.perform_async(id) if Radar::ValueListSyncService.syncs?(object_type)
    end
end
