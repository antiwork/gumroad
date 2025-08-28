# frozen_string_literal: true

class BlockedCustomerObject < ApplicationRecord
  SUPPORTED_OBJECT_TYPES = {
    email: "email",
    charge_processor_fingerprint: "charge_processor_fingerprint"
  }.freeze

  has_paper_trail

  belongs_to :seller, class_name: "User"

  validates_presence_of :object_type, :object_value
  validates_presence_of :buyer_email, if: -> { object_type == SUPPORTED_OBJECT_TYPES[:charge_processor_fingerprint] }
  validates_inclusion_of :object_type, in: SUPPORTED_OBJECT_TYPES.values
  validates :object_value, email_format: true, if: -> { object_type == SUPPORTED_OBJECT_TYPES[:email] }
  validates :buyer_email, email_format: true, allow_blank: true

  scope :email, -> { where(object_type: SUPPORTED_OBJECT_TYPES[:email]) }
  scope :active, -> { where.not(blocked_at: nil) }
  scope :inactive, -> { where(blocked_at: nil) }

  def self.email_blocked?(email:, seller_id:)
    return false if email.blank?

    active.email.where(seller_id:, object_value: comparable_email(email:)).exists?
  end

  def self.block_email!(email:, seller_id:)
    find_or_initialize_by(seller_id:, object_type: SUPPORTED_OBJECT_TYPES[:email], object_value: email).tap do |blocked_object|
      return true if blocked_object.blocked_at?

      blocked_object.blocked_at = DateTime.current
      blocked_object.save!
    end
  end

  def self.comparable_email(email:)
    local_part, domain = email.downcase.split("@")
    local_part = local_part.split("+").first # normalize plus sub-addressing
    local_part = local_part.delete(".") # remove dots

    "#{local_part}@#{domain}"
  end
  private_class_method :comparable_email

  def unblock!
    return true if blocked_at.nil?

    update!(blocked_at: nil)
  end
end
