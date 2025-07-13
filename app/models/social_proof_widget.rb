# frozen_string_literal: true

class SocialProofWidget < ApplicationRecord
  has_paper_trail

  belongs_to :user

  # Association with links/products
  has_and_belongs_to_many :links

  # Analytics associations
  has_many :social_proof_widget_events, dependent: :destroy
  has_many :social_proof_widget_analytics, dependent: :destroy
  has_many :social_proof_widget_purchases, dependent: :destroy

  # Alias title_text to the `title` attribute to match the controller's transformation.
  alias_attribute :title_text, :title

  # Dynamically load available icons from the assets directory
  def self.available_icons
    @available_icons ||= begin
      icons_path = Rails.root.join('app', 'assets', 'images', 'icons')
      return [] unless Dir.exist?(icons_path)

      Dir.entries(icons_path)
         .select { |file| file.end_with?('.svg') }
         .map { |file| file.chomp('.svg') }
         .sort
    end
  end

  validates :name, presence: true
  validates :title, presence: true
  validates :cta_type, inclusion: { in: %w[button link none],
                                    message: "%{value} is not a valid CTA type" }
  validates :image_type, inclusion: {
    in: %w[
      product_thumbnail
      custom_image
      icon
      none
    ],
    message: "%{value} is not a valid image type"
  }
  validates :icon_name, presence: true, if: -> { image_type == 'icon' }
  validates :icon_name, inclusion: {
    in: -> { SocialProofWidget.available_icons },
    message: "%{value} is not a valid icon name"
  }, if: -> { image_type == 'icon' }
  validates :visibility, inclusion: { in: %w[all new returning],
                                     message: "%{value} is not a valid visibility type" }

  def status
    published? ? 'published' : 'unpublished'
  end

  def status=(value)
    self.published = (value == 'published')
  end

  scope :published, -> { where(published: true) }
  scope :unpublished, -> { where(published: false) }
  scope :visible_for_all, -> { where(visibility: 'all') }
  scope :visible_for_new_visitors, -> { where(visibility: 'new') }
  scope :visible_for_returning_visitors, -> { where(visibility: 'returning') }

  # Analytics methods
  def current_analytics(days = 30)
    start_date = days.days.ago
    end_date = Date.current

    # Get events within the date range
    events_in_range = social_proof_widget_events.between_dates(start_date, end_date)
    purchases_in_range = social_proof_widget_purchases.between_dates(start_date, end_date)

    # Calculate metrics within the same date range
    clicks_in_range = events_in_range.clicks.count
    purchases_count = purchases_in_range.count
    revenue_cents = purchases_in_range.sum(:revenue_cents)

    # Calculate conversion rate using clicks within the same range
    conversion_rate = clicks_in_range > 0 ? (purchases_count.to_f / clicks_in_range * 100).round(4) : 0.0

    {
      impressions: impressions_count,
      clicks: clicks_count,
      purchases: purchases_count,
      revenue_cents: revenue_cents,
      conversion_rate: conversion_rate
    }
  end

  def analytics_summary
    stats = current_analytics
    {
      clicks: stats[:clicks],
      conversion_rate: "#{stats[:conversion_rate]}%",
      revenue: Money.new(stats[:revenue_cents], "USD").format,
      status: status
    }
  end

  # Increment counters
  def increment_impression!
    increment!(:impressions_count)
  end

  def increment_click!
    increment!(:clicks_count)
  end

  def track_purchase!(purchase_id, revenue_cents)
    SocialProofWidgetPurchase.track_purchase(id, purchase_id, revenue_cents)
    # Update the widget's revenue counter
    increment!(:revenue_cents, revenue_cents)
  end

  def visible_for_visitor_type?(visitor_type)
    case visibility
    when 'all'
      true
    when 'new'
      visitor_type == 'new'
    when 'returning'
      visitor_type == 'returning'
    else
      false
    end
  end
end
