# frozen_string_literal: true

# Assigns a product to a storefront (see Storefront). A product can belong to at most one
# storefront — enforced by a unique index on link_id — and products with no assignment keep
# showing on the account's main profile, which preserves the behavior of every existing product.
class StorefrontProduct < ApplicationRecord
  belongs_to :storefront
  belongs_to :product, class_name: "Link", foreign_key: :link_id

  validates :link_id, uniqueness: true
end
