# frozen_string_literal: true

class SocialProofWidgetPurchase < ApplicationRecord
  belongs_to :social_proof_widget
  belongs_to :purchase

  validates :purchase_id, uniqueness: true
  validates :revenue_cents, presence: true, numericality: { greater_than: 0 }
  validates :occurred_at, presence: true

  scope :for_widget, ->(widget_id) { where(social_proof_widget_id: widget_id) }
  scope :on_date, ->(date) { where(occurred_at: date.beginning_of_day..date.end_of_day) }
  scope :between_dates, ->(start_date, end_date) { where(occurred_at: start_date.beginning_of_day..end_date.end_of_day) }

  # Track a purchase from a widget
  def self.track_purchase(widget_id, purchase_id, revenue_cents)
    create!(
      social_proof_widget_id: widget_id,
      purchase_id: purchase_id,
      revenue_cents: revenue_cents,
      occurred_at: Time.current
    )
  rescue ActiveRecord::RecordNotUnique
    # Purchase already tracked for this widget, ignore
    nil
  end

  def revenue_dollars
    revenue_cents / 100.0
  end
end
