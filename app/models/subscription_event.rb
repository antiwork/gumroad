# frozen_string_literal: true

class SubscriptionEvent < ApplicationRecord
  belongs_to :subscription
  belongs_to :seller, class_name: "User"

  before_validation :assign_seller, on: :create

  validates :event_type, :occurred_at, presence: true
  validate :consecutive_event_type_not_duplicated

  enum event_type: %i[deactivated restarted]

  private
    def assign_seller
      self.seller_id = subscription.seller_id
    end

    def consecutive_event_type_not_duplicated
      return unless subscription.present? && occurred_at.present?

      latest_event = subscription.subscription_events.order(:occurred_at, :id).last
      return if latest_event.blank? || latest_event.event_type != event_type.to_s

      errors.add(:event_type, "already exists as the latest event type")
    end
end
