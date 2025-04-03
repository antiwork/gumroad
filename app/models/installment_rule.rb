# frozen_string_literal: true

class InstallmentRule < ApplicationRecord
  has_paper_trail version: :paper_trail_version

  include Deletable

  belongs_to :installment, optional: true

  # To show the proper time period to a user, we need to store this.
  # To a user, they should see "1 week" instead of "7 days."
  HOUR = "hour"
  DAY = "day"
  WEEK = "week"
  MONTH = "month"

  ABANDONED_CART_DELAYED_DELIVERY_TIME_IN_SECONDS = 24.hours.to_i

  validates_presence_of :installment, :version
  validate :to_be_published_at_cannot_be_in_the_past
  validate :to_be_published_at_must_exist_for_non_workflow_posts

  # We increment the version when delivery date changes so the correct job is processed, not an old one. We have the version starting
  # at 1 even though the schema shows a default value of 0. If there is no rule to go with an installment, we pass version = 0 as a
  # parameter so changing version to start at 0 will disrupt current installment jobs in the queue.
  before_save :increment_version, if: :delivery_date_changed?

  # Public: Converts the delayed_delivery_time back into the number the creator entered using the time period of the rule
  #
  # Examples
  #   delayed_delivery_time = 432000, time_period = "DAY"
  #   displayable_time_duration
  #   #=> 5
  #   delayed_delivery_time = 72000, time_period = "HOUR"
  #   displayable_time_duration
  #   # => 20
  #
  # Returns an integer
  def displayable_time_duration
    case time_period
    when HOUR
      period = 1.hour
    when DAY
      period = 1.day
    when WEEK
      period = 1.week
    when MONTH
      period = 1.month
    end
    (delayed_delivery_time / period).to_i
  end

  private
    # Private: Increments version of InstallmentRule. This is so PublishInstallment jobs are ignored if the version of the job does not match the
    # most recent version of the InstallmentRule. We want to update the version every time the creator changes when it is scheduled.
    def increment_version
      self[:version] = version + 1
    end

    def delivery_date_changed?
      delayed_delivery_time_changed? || to_be_published_at_changed?
    end

    def to_be_published_at_must_exist_for_non_workflow_posts
      return if installment.blank?
      return if installment.workflow.present?
      return if to_be_published_at.present?

      errors.add(:base, "Please select a date and time in the future.")
    end

    def to_be_published_at_cannot_be_in_the_past
      return if deleted_at_changed?
      return if to_be_published_at.blank?
      return if to_be_published_at > Time.current

      errors.add(:base, "Please select a date and time in the future.")
    end
end
