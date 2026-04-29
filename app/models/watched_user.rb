# frozen_string_literal: true

class WatchedUser < ApplicationRecord
  include ExternalId
  include Deletable

  belongs_to :user
  belongs_to :created_by, class_name: "User", optional: true

  validates :revenue_threshold_cents, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validate :no_other_alive_watch_for_user, on: :create

  scope :for_user, ->(user) { where(user: user) }

  def sync!
    update!(
      revenue_cents: user.sales_cents_total,
      unpaid_balance_cents: user.unpaid_balance_cents,
      last_synced_at: Time.current
    )
  end

  private
    def no_other_alive_watch_for_user
      return unless user_id
      return unless self.class.for_user(user).alive.where.not(id: id).exists?

      errors.add(:base, "User is already being watched")
    end
end
