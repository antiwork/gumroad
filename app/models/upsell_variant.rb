# frozen_string_literal: true

class UpsellVariant < ApplicationRecord
  include Deletable, ExternalId

  belongs_to :upsell
  belongs_to :selected_variant, class_name: "BaseVariant"
  belongs_to :offered_variant, class_name: "BaseVariant"

  validates_presence_of :upsell, :selected_variant, :offered_variant

  validate :variants_belong_to_upsell_product, if: :alive?

  private
    def variants_belong_to_upsell_product
      if selected_variant.link != upsell.product || offered_variant.link != upsell.product
        errors.add(:base, "The selected variant and the offered variant must belong to the upsell's offered product.")
      end
    end
end
