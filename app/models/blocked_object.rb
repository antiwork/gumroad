# frozen_string_literal: true

class BlockedObject
  include Mongoid::Document
  include Mongoid::Timestamps

  # Block the IP for 6 months so that if the IP gets reallocated can be used again
  # Also prevents the list of blocked IPs to grow indefinitely
  IP_ADDRESS_BLOCKING_DURATION_IN_MONTHS = 6

  field :object_type, type: String
  field :object_value, type: String
  field :blocked_at, type: DateTime
  field :expires_at, type: DateTime
  field :blocked_by, type: Integer

  scope :email,                        -> { where(object_type: BLOCKED_OBJECT_TYPES[:email]) }
  scope :email_domain,                 -> { where(object_type: BLOCKED_OBJECT_TYPES[:email_domain]) }
  scope :browser_guid,                 -> { where(object_type: BLOCKED_OBJECT_TYPES[:browser_guid]) }
  scope :ip_address,                   -> { where(object_type: BLOCKED_OBJECT_TYPES[:ip_address]) }
  scope :charge_processor_fingerprint, -> { where(object_type: BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint]) }
  scope :product,                      -> { where(object_type: BLOCKED_OBJECT_TYPES[:product]) }
  scope :active,                       -> { where(:blocked_at.ne => nil).any_of({ expires_at: nil }, { :expires_at.gt => Time.current }) }

  validates_inclusion_of :object_type, in: BLOCKED_OBJECT_TYPES.values
  validate :expires_on_required_for_active_object_type_ip_address

  class << self
    def block!(object_type, object_value, blocking_user_id, expires_in: nil)
      blocked_object = find_or_initialize_by(object_type:, object_value:)
      blocked_at = Time.current
      blocked_object.blocked_at = blocked_at
      blocked_object.blocked_by = blocking_user_id
      blocked_object.expires_at = blocked_at + expires_in if expires_in.present?
      blocked_object.save!
      blocked_object
    end

    def unblock!(object_value)
      blocked_object = find_by(object_value:)

      blocked_object.unblock! if blocked_object
    end

    def find_active_object(object_value)
      active.find_by(object_value:)
    rescue NoMethodError
      BlockedObject.none
    end

    def find_active_objects(object_values)
      active.where(:object_value.in => object_values)
    rescue NoMethodError
      BlockedObject.none
    end
  end

  def unblock!
    self.blocked_at = nil
    self.expires_at = nil
    self.save!
  end

  def blocked?
    blocked_at.present? && (expires_at.nil? || expires_at > Time.current)
  end

  def expires_on_required_for_active_object_type_ip_address
    return if object_type != BLOCKED_OBJECT_TYPES[:ip_address]
    return if blocked_at.nil?
    return if expires_at.present?

    errors.add(:expires_at, :blank)
  end
end
