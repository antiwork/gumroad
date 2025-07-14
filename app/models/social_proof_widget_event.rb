# frozen_string_literal: true

class SocialProofWidgetEvent < ApplicationRecord
  belongs_to :social_proof_widget
  belongs_to :user, optional: true
  belongs_to :purchase, optional: true

  validates :event_type, presence: true, inclusion: { in: %w[impression click purchase] }

  scope :impressions, -> { where(event_type: 'impression') }
  scope :clicks, -> { where(event_type: 'click') }
  scope :purchases, -> { where(event_type: 'purchase') }
  scope :for_widget, ->(widget_id) { where(social_proof_widget_id: widget_id) }
  scope :on_date, ->(date) { where(created_at: date.beginning_of_day..date.end_of_day) }
  scope :between_dates, ->(start_date, end_date) { where(created_at: start_date.beginning_of_day..end_date.end_of_day) }

  # Track an impression when the widget is shown
  def self.track_impression(widget_id, session_id, user_id = nil)
    create!(
      social_proof_widget_id: widget_id,
      event_type: 'impression',
      session_id: session_id
    )
  end

  # Track a click when the widget is clicked
  def self.track_click(widget_id, session_id, user_id = nil)
    create!(
      social_proof_widget_id: widget_id,
      event_type: 'click',
      session_id: session_id
    )
  end

  # Track a purchase when a click leads to a purchase
  def self.track_purchase(widget_id, session_id, purchase_id, revenue_cents, user_id = nil)
    create!(
      social_proof_widget_id: widget_id,
      event_type: 'purchase',
      session_id: session_id,
      purchase_id: purchase_id,
      revenue_cents: revenue_cents
    )
  end
end
