# frozen_string_literal: true

class Variant < BaseVariant
  include Variant::Prices

  belongs_to :variant_category, optional: true

  has_many :prices, class_name: "VariantPrice"
  has_many :alive_prices, -> { alive }, class_name: "VariantPrice"
  has_and_belongs_to_many :skus, join_table: :skus_variants
  has_many :product_files_archives
  has_many :subscription_plan_changes, foreign_key: "base_variant_id"

  validates_presence_of :variant_category
  validate :price_must_be_within_range
  validates :duration_in_minutes, numericality: { greater_than: 0 }, if: -> { link.native_type == Link::NATIVE_TYPE_CALL }

  before_create :set_position
  after_save :set_customizable_price

  delegate :link, to: :variant_category
  delegate :user, to: :link

  scope :in_order, -> { order(position_in_category: :asc, created_at: :asc) }

  def alive_skus
    skus.alive
  end

  def name_displayable
    "#{link.name} (#{name})"
  end

  def has_prices?
    prices.alive.exists? || link.is_tiered_membership
  end

  def as_json(options = {})
    json = super(options)
    if has_prices?
      json["is_customizable_price"] = customizable_price.to_s == "true"
      json["recurrence_price_values"] = recurrence_price_values(for_edit: true)
    end
    json
  end

  def recurrence_price_values(for_edit: false, subscription_attrs: nil)
    recurrence_price_values = {}
    BasePrice::Recurrence.all.each do |recurrence|
      use_subscription_price = subscription_attrs.present? && subscription_attrs[:variants].include?(self) && recurrence == subscription_attrs[:recurrence]
      price = (alive? && link.recurrence_price_enabled?(recurrence)) ? alive_prices.is_buy.find_by(recurrence:) : nil
      # if rendering price info for a subscription, include the subscription's
      # recurrence price even if it is deleted
      if !price.present? && use_subscription_price
        price = prices.is_buy.find { |p| p.recurrence == recurrence }
      end

      if for_edit
        if price.present?
          recurrence_price_values[recurrence] = {
            enabled: true,
            price_cents: price.price_cents,
            suggested_price_cents: price.suggested_price_cents,
            # TODO: :product_edit_react cleanup
            price: price.price_formatted_without_symbol,
          }
          # TODO: :product_edit_react cleanup
          recurrence_price_values[recurrence][:suggested_price] = price.suggested_price_formatted_without_symbol if price.suggested_price_cents.present?
        else
          recurrence_price_values[recurrence] = {
            enabled: false
          }
        end
      else
        if price.present?
          price_cents = use_subscription_price ? subscription_attrs[:price_cents] : price.price_cents
          recurrence_price_values[recurrence] = {
            price_cents:,
            suggested_price_cents: price.suggested_price_cents,
          }
        end
      end
    end
    recurrence_price_values
  end

  private
    def set_position
      return if self.position_in_category.present?
      return unless variant_category
      previous = variant_category.variants.alive.in_order.last
      if previous
        self.position_in_category = previous.position_in_category.present? ? previous.position_in_category + 1 : variant_category.variants.alive.in_order.count
      else
        self.position_in_category = 0
      end
    end
end
