# frozen_string_literal: true

class VariantCategory < ApplicationRecord
  include ExternalId
  include Deletable
  include FlagShihTzu

  has_many :variants
  has_many :alive_variants, -> { alive }, class_name: "Variant"
  # touch: true because soft-deleting or renaming this row moves the product's displayed
  # price: Link#tier_category is scoped `alive.is_tier_category`, so losing it drops
  # lowest_tier_price to the $0 fallback. Pages::ProfileData keys its cached storefront
  # payload on links.updated_at, which no write here would otherwise move.
  belongs_to :link, touch: true, optional: true

  # For tiered membership products, variants are "tiers"
  has_many :tiers, -> { alive }, class_name: "Variant"
  has_one :default_tier, -> { alive }, class_name: "Variant"

  has_flags 1 => :DEPRECATED_variants_are_allowed_to_have_product_files,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  after_commit :invalidate_product_cache

  scope :is_tier_category, -> { where(title: "Tier") }

  def has_alive_grouping_variants_with_purchases?
    alive_variants.each do |variant|
      return true if variant.purchases.all_success_states.exists? && variant.product_files.alive.exists?
    end
    false
  end

  def available?
    return true if alive_variants.empty?

    alive_variants.any?(&:available?)
  end

  def as_json(*)
    { id: external_id, title: }.stringify_keys
  end

  private
    def invalidate_product_cache
      link.invalidate_cache if link.present?
    end
end
