# frozen_string_literal: true

module SocialProofWidget::Sorting
  extend ActiveSupport::Concern

  SORT_KEYS = ["name", "clicks", "conversions", "revenue", "status"]

  SORT_KEYS.each do |key|
    const_set(key.upcase, key)
  end

  class_methods do
    def sorted_by(key: nil, direction: nil)
      direction = direction == "desc" ? "desc" : "asc"
      case key
      when NAME
        order(name: direction)
      when CLICKS
        left_outer_joins(:social_proof_widget_metrics)
          .group(:id)
          .order("SUM(social_proof_widget_metrics.clicks_count) #{direction}")
      when CONVERSIONS
        left_outer_joins(:conversions)
          .group(:id)
          .order("COUNT(conversions.id) #{direction}")
      when REVENUE
        left_outer_joins(conversions: :purchase)
          .group(:id)
          .order("SUM(purchases.price_cents) #{direction}")
      when STATUS
        order(published: direction)
      else
        all
      end
    end
  end
end
