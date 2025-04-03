# frozen_string_literal: true

class Sku < BaseVariant
  belongs_to :link, optional: true
  has_and_belongs_to_many :variants, join_table: :skus_variants

  delegate :user, to: :link

  validates_presence_of :link

  def as_json(options = {})
    json = super(options)
    json["custom_sku"] = custom_sku if custom_sku
    json
  end

  def sku_category_name
    link.sku_title
  end

  def custom_name_or_external_id
    custom_sku.presence || external_id
  end

  # Public: This method returns the remaining inventory considering the product's overall quantity limitation as well as this SKU's.
  # Returns Float::INFINITY when no inventory limitation exists.
  def inventory_left
    product_quantity_left = link.max_purchase_count ? [(link.max_purchase_count - link.sales_count_for_inventory), 0].max : Float::INFINITY
    quantity_left ? [quantity_left, product_quantity_left].min : product_quantity_left
  end

  def to_option_for_product
    {
      id: external_id,
      name:,
      quantity_left:,
      description: description || "",
      price_difference_cents:,
      recurrence_price_values: nil,
      is_pwyw: false,
      duration_in_minutes:,
    }
  end
end
