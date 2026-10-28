# frozen_string_literal: true

# One row per (follower, product) pair: the visitor asked to hear about this product
# when it launches. A separate table rather than a column on `followers`, because a
# follow is unique per (email, seller) and one row can only name one product.
class WaitlistEntry < ApplicationRecord
  belongs_to :product, class_name: "Link"
  belongs_to :follower

  validates :product_id, uniqueness: { scope: :follower_id }
end
