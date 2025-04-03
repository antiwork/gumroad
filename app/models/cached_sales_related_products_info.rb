# frozen_string_literal: true

class CachedSalesRelatedProductsInfo < ApplicationRecord
  belongs_to :product, class_name: "Link"
  after_initialize :assign_default_counts_value
  validate :counts_has_valid_format

  def normalized_counts = counts&.transform_keys(&:to_i)

  private
    def assign_default_counts_value
      return if persisted?
      self.counts ||= {}
    end

    def counts_has_valid_format
      # `counts` must be a hash of { product_id => sales count }
      # The json format forces the keys to be strings, so we need to check that the keys are actually integers.
      return if counts.is_a?(Hash) && counts.all? { _1.to_s == _1.to_i.to_s && _2.is_a?(Integer) }
      errors.add(:counts, "has invalid format")
    end
end
