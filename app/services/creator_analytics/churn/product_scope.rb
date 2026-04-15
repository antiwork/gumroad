# frozen_string_literal: true

class CreatorAnalytics::Churn::ProductScope
  attr_reader :seller

  def initialize(seller:)
    @seller = seller
  end

  def subscription_products
    @subscription_products ||= seller
      .products_for_creator_analytics
      .select { |product| product.is_recurring_billing? || product.is_tiered_membership? }
  end

  def product_map
    @product_map ||= subscription_products.to_h do |product|
      [
        product.id,
        {
          id: product.id,
          external_id: product.external_id,
          permalink: product.unique_permalink,
          name: product.name
        }
      ]
    end
  end

  def earliest_analytics_date
    @earliest_analytics_date ||= (first_sale_date || seller.created_at.in_time_zone(seller.timezone).to_date)
  end

  def first_sale_date
    @first_sale_date ||= begin
      first_sale = seller.first_sale_created_at_for_analytics
      first_sale&.in_time_zone(seller.timezone)&.to_date
    end
  end
end
