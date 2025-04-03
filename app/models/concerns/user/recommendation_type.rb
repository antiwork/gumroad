# frozen_string_literal: true

module User::RecommendationType
  TYPES = [
    "no_recommendations",
    "own_products",
    "gumroad_affiliates_products",
    "directly_affiliated_products"
  ].freeze

  TYPES.each do |type|
    self.const_set(type.upcase, type)
  end
end
