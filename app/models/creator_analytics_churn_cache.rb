# frozen_string_literal: true

class CreatorAnalyticsChurnCache < ApplicationRecord
  belongs_to :user

  validates :date, presence: true, uniqueness: { scope: :user_id }
  validates :customer_churn_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :churned_subscribers, numericality: { greater_than_or_equal_to: 0 }
  validates :churned_mrr_cents, numericality: { greater_than_or_equal_to: 0 }

  scope :for_date_range, ->(start_date, end_date) { where(date: start_date..end_date) }
  scope :recent, -> { where("date >= ?", 90.days.ago) }
end

