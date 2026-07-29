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

  # The addresses here are copied off existing buyers rather than typed by anyone, and some of
  # those rows were stored before we started refusing addresses that carry an invisible
  # character. This is a blocking control, so it has to fail open on the address and still record
  # the block: refusing to save would mean a seller asks us to block a buyer, we raise, and the
  # buyer stays unblocked. Normalizing also keeps the stored value comparable to the normalized
  # address that email_blocked? looks up.
  before_validation :normalize_email_values

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
    # Invisible characters are removed before comparing so a block still matches regardless of
    # whether the block or the incoming purchase carries one. Blocks recorded before we started
    # normalizing hold the character in object_value, while incoming purchase emails are now
    # cleaned — without this, such a block would silently stop matching and a buyer blocked for
    # fraud could purchase again. Normalizing both sides of the comparison fixes those rows
    # without needing to rewrite them.
    local_part, domain = InvisibleCharacters.normalize_email(email).downcase.split("@")
    local_part = local_part.split("+").first # normalize plus sub-addressing
    local_part = local_part.delete(".") # remove dots

    "#{local_part}@#{domain}"
  end
  private_class_method :comparable_email

  def unblock!
    return true if blocked_at.nil?

    update!(blocked_at: nil)
  end

  private
    def normalize_email_values
      if object_type == SUPPORTED_OBJECT_TYPES[:email] && object_value.present?
        self.object_value = InvisibleCharacters.normalize_email(object_value)
      end
      self.buyer_email = InvisibleCharacters.normalize_email(buyer_email) if buyer_email.present?
    end
end
