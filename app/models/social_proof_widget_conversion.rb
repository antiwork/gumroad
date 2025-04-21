# frozen_string_literal: true

class SocialProofWidgetConversion < ApplicationRecord
  belongs_to :social_proof_widget
  belongs_to :purchase

  validates :social_proof_widget_id, uniqueness: { scope: :purchase_id }

  def self.track_conversion(widget, purchase)
    find_or_create_by!(
      social_proof_widget: widget,
      purchase: purchase
    )
  end

  def self.total_revenue_cents
    joins(:purchase).sum("purchases.price_cents")
  end
end
