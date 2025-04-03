# frozen_string_literal: true

# Helper methods for tiered membership products with tier-level pricing
module ProductTieredPricingHelpers
  def tier_pricing_values(product)
    product.tier_category.variants.alive.map(&:reload).map do |tier|
      json = tier.as_json
      { name: tier.name, pwyw: json["is_customizable_price"], values: json["recurrence_price_values"] }
    end
  end
end
