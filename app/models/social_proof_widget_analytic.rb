# frozen_string_literal: true

class SocialProofWidgetAnalytic < ApplicationRecord
  belongs_to :social_proof_widget

  validates :date, presence: true, uniqueness: { scope: :social_proof_widget_id }
  validates :impressions, :clicks, :purchases, :revenue_cents, presence: true, numericality: { greater_than_or_equal_to: 0 }

  scope :for_widget, ->(widget_id) { where(social_proof_widget_id: widget_id) }
  scope :on_date, ->(date) { where(date: date) }
  scope :between_dates, ->(start_date, end_date) { where(date: start_date..end_date) }
  scope :recent, ->(days = 30) { where(date: days.days.ago..Date.current) }

  # Calculate and store analytics for a specific widget and date
  def self.calculate_for_widget_and_date(widget_id, date)
    events = SocialProofWidgetEvent.for_widget(widget_id).on_date(date)

    impressions_count = events.impressions.count
    clicks_count = events.clicks.count
    purchases_count = events.purchases.count
    revenue_total = events.purchases.sum(:revenue_cents)

    conversion_rate = clicks_count > 0 ? (purchases_count.to_f / clicks_count * 100).round(4) : 0.0

    find_or_initialize_by(social_proof_widget_id: widget_id, date: date).tap do |analytic|
      analytic.impressions = impressions_count
      analytic.clicks = clicks_count
      analytic.purchases = purchases_count
      analytic.revenue_cents = revenue_total
      analytic.conversion_rate = conversion_rate
      analytic.save!
    end
  end

  # Calculate analytics for all widgets for a specific date
  def self.calculate_for_date(date)
    SocialProofWidget.find_each do |widget|
      calculate_for_widget_and_date(widget.id, date)
    end
  end

  # Get total analytics for a widget across a date range
  def self.totals_for_widget(widget_id, start_date = 30.days.ago, end_date = Date.current)
    analytics = for_widget(widget_id).between_dates(start_date, end_date)

    total_impressions = analytics.sum(:impressions)
    total_clicks = analytics.sum(:clicks)
    total_purchases = analytics.sum(:purchases)
    total_revenue = analytics.sum(:revenue_cents)

    avg_conversion_rate = total_clicks > 0 ? (total_purchases.to_f / total_clicks * 100).round(4) : 0.0

    {
      impressions: total_impressions,
      clicks: total_clicks,
      purchases: total_purchases,
      revenue_cents: total_revenue,
      conversion_rate: avg_conversion_rate
    }
  end

  def revenue_dollars
    revenue_cents / 100.0
  end

  def formatted_conversion_rate
    "#{conversion_rate}%"
  end
end
