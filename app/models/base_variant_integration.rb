# frozen_string_literal: true

class BaseVariantIntegration < ApplicationRecord
  include Deletable

  belongs_to :base_variant, optional: true
  belongs_to :integration, optional: true

  validates_presence_of :base_variant_id, :integration_id
  validates_uniqueness_of :integration_id, scope: %i[base_variant_id deleted_at], unless: :deleted?
  validate :variants_with_same_integration_are_from_a_single_product

  private
    def variants_with_same_integration_are_from_a_single_product
      return unless BaseVariantIntegration.exists?(integration:)

      BaseVariantIntegration.where(integration:).each do |base_variant_integration|
        errors.add(:base, "Integration has already been taken by a variant from a different product.") if base_variant_integration.base_variant.link.id != base_variant.link.id
      end
    end
end
