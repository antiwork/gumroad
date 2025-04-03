# frozen_string_literal: true

class RecommendedPurchaseInfo < ApplicationRecord
  include FlagShihTzu

  belongs_to :purchase, optional: true
  belongs_to :recommended_link, class_name: "Link", optional: true
  belongs_to :recommended_by_link, class_name: "Link", optional: true

  validates_inclusion_of :recommender_model_name, in: RecommendedProductsService::MODELS, allow_nil: true

  has_flags 1 => :is_recurring_purchase,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  scope :successful_by_date, lambda { |date|
    joins(:purchase).where("recommended_purchase_infos.created_at > ?", date).where("purchases.purchase_state = 'successful'")
  }
end
