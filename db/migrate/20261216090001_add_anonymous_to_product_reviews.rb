# frozen_string_literal: true

class AddAnonymousToProductReviews < ActiveRecord::Migration[7.1]
  def change
    # Nullable with no default: every existing row stays NULL, which reads as "no choice made" and
    # falls through to the account identity. That is what keeps this backfill-free.
    add_column :product_reviews, :anonymous, :boolean
  end
end
