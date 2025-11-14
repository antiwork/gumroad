# frozen_string_literal: true

class BalanceLoadCreditCard < ApplicationRecord
  belongs_to :user
  has_many :balance_loads, dependent: :restrict_with_error

  validates :stripe_customer_id, :stripe_fingerprint, :visual, :card_type, presence: true
  validates :expiry_month, :expiry_year, presence: true
  validates :expiry_month, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 12 }
  validates :expiry_year, numericality: { only_integer: true, greater_than: 2000 }
  validate :validate_not_expired, on: :create
  validate :validate_only_one_default_per_user, if: :is_default?

  scope :active, -> { where(deleted_at: nil) }
  scope :for_user, ->(user_id) { where(user_id:).active }
  scope :default_card, -> { active.where(is_default: true) }

  # Soft delete
  def soft_delete!
    update!(deleted_at: Time.current, is_default: false)
  end

  def expired?
    return false if expiry_month.nil? || expiry_year.nil?

    expiry_date = Date.new(expiry_year, expiry_month, -1)
    expiry_date < Date.current
  end

  def last_four
    visual.split.last
  end

  def expiry_visual
    return nil if expiry_month.nil? || expiry_year.nil?

    "#{expiry_month.to_s.rjust(2, '0')}/#{expiry_year.to_s[-2, 2]}"
  end

  def as_json(options = {})
    {
      id: id,
      visual: visual.gsub("*", "•"),
      card_type: card_type,
      expiry: expiry_visual,
      is_default: is_default,
      expired: expired?
    }
  end

  private

  def validate_not_expired
    errors.add(:base, "Card has expired") if expired?
  end

  def validate_only_one_default_per_user
    return unless user_id
    return unless is_default_changed? || new_record?

    existing = BalanceLoadCreditCard.where(user_id:, is_default: true)
                                     .where.not(id:)
                                     .active
                                     .exists?
    errors.add(:is_default, "User already has a default card") if existing
  end
end
