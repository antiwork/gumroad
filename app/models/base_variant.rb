# frozen_string_literal: true

class BaseVariant < ApplicationRecord
  include ActionView::Helpers::SanitizeHelper
  include CurrencyHelper
  include ExternalId
  include Deletable
  include WithProductFilesManyToMany
  include FlagShihTzu
  include MaxPurchaseCount
  include Integrations
  include RichContents

  MINIMUM_DAYS_TIL_EXISTING_MEMBERSHIP_PRICE_CHANGE = 7

  has_and_belongs_to_many :purchases
  has_many :subscriptions, through: :purchases
  has_many :base_variant_integrations
  has_many :live_base_variant_integrations, -> { alive }, class_name: "BaseVariantIntegration"
  has_many :active_integrations, through: :live_base_variant_integrations, source: :integration

  delegate :has_stampable_pdfs?, to: :link

  scope :in_order, -> { order(created_at: :asc) }

  has_flags 1 => :is_default_sku,
            2 => :apply_price_changes_to_existing_memberships,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  after_commit :invalidate_product_cache,
               if: ->(base_variant) { base_variant.previous_changes.present? && base_variant.previous_changes.present? != [:updated_at] }
  after_commit :update_product_search_index

  validates_presence_of :name, unless: -> { link.native_type == Link::NATIVE_TYPE_COFFEE }
  validate :max_purchase_count_is_greater_than_or_equal_to_inventory_sold
  validate :price_difference_cents_validation
  validate :apply_price_changes_to_existing_memberships_settings

  before_validation :strip_subscription_price_change_message, unless: -> { subscription_price_change_message.nil? }

  def mark_deleted
    super
    DeleteProductRichContentWorker.perform_async(variant_category.link_id, id)
    DeleteProductFilesArchivesWorker.perform_async(variant_category.link_id, id)
  end

  def price_difference_in_currency_units
    return price_difference_cents if link.single_unit_currency?

    price_difference_cents.to_i / 100.0
  end

  def price_formatted_without_dollar_sign
    return 0 unless price_difference_cents

    display_price(symbol: false)
  end

  def quantity_left
    return nil if max_purchase_count.nil?

    [max_purchase_count - sales_count_for_inventory, 0].max
  end

  def available?
    return false if deleted?
    return true if max_purchase_count.nil?

    quantity_left > 0
  end

  def sold_out?
    return false if max_purchase_count.nil?

    quantity_left == 0
  end

  def free?
    !((price_difference_cents.present? && price_difference_cents > 0) || prices.alive.is_buy.where("price_cents > 0").exists?)
  end

  def as_json(options = {})
    if options[:for_views]
      variant_quantity_left = quantity_left
      variant_json = {
        "option" => name,
        "name" => name == "Untitled" ? link.name : name,
        "description" => description,
        "id" => external_id,
        "max_purchase_count" => max_purchase_count,
        "price_difference_cents" => price_difference_cents,
        "price_difference_in_currency_units" => price_difference_in_currency_units,
        "showing" => price_difference_cents != 0,
        "quantity_left" => variant_quantity_left,
        "amount_left_title" => variant_quantity_left ? "#{variant_quantity_left} left" : "",
        "displayable" => name,
        "sold_out" => variant_quantity_left == 0,
        "price_difference" => price_formatted_without_dollar_sign,
        "currency_symbol" => link.currency_symbol,
        "product_files_ids" => product_files.collect(&:external_id),
      }
      if options[:for_seller] == true
        variant_json["active_subscriber_count"] = active_subscribers_count
        variant_json["settings"] = {
          apply_price_changes_to_existing_memberships: apply_price_changes_to_existing_memberships? ?
            { enabled: true, effective_date: subscription_price_change_effective_date, custom_message: subscription_price_change_message } :
            { enabled: false }
        }
      end

      variant_json["integrations"] = {}
      Integration::ALL_NAMES.each do |name|
        variant_json["integrations"][name] = find_integration_by_name(name).present?
      end

      variant_json
    else
      {
        "id" => external_id,
        "max_purchase_count" => max_purchase_count,
        "name" => name,
        "description" => description,
        "price_difference_cents" => price_difference_cents
      }
    end
  end

  def to_option(subscription_attrs: nil)
    {
      id: external_id,
      name: name == "Untitled" ? link.name : name || "",
      quantity_left:,
      description: description || "",
      price_difference_cents:,
      recurrence_price_values: link.is_tiered_membership ? recurrence_price_values(subscription_attrs:) : nil,
      is_pwyw: !!customizable_price,
      duration_in_minutes:,
    }
  end

  def sales_count_for_inventory
    purchases.counts_towards_inventory.sum(:quantity)
  end

  def is_downloadable?
    return false if link.purchase_type == "rent_only"
    return false if has_stampable_pdfs?
    return false if stream_only?

    true
  end

  def stream_only?
    link.has_same_rich_content_for_all_variants? ? link.product_files.alive.all?(&:stream_only?) : super
  end

  def active_subscribers_count
    return 0 unless link.is_recurring_billing?

    link.successful_sales_count(variant: self)
  end

  private
    def display_price(options = {})
      attrs = { no_cents_if_whole: true, symbol: true }.merge(options)
      MoneyFormatter.format(price_difference_cents, link.price_currency_type.to_sym, attrs)
    end

    def invalidate_product_cache
      link.invalidate_cache if link.present?
    end

    def price_difference_cents_validation
      if price_difference_cents && price_difference_cents < 0
        errors.add(:base, "Please enter a price that is equal to or greater than the price of the product.")
      end

      if link.native_type == Link::NATIVE_TYPE_COFFEE && price_difference_cents && price_difference_cents <= 0
        errors.add(:base, "Price difference cents must be greater than 0")
      end
    end

    def max_purchase_count_is_greater_than_or_equal_to_inventory_sold
      return unless max_purchase_count_changed?
      return if max_purchase_count.nil?
      cached_sales_count_for_inventory = sales_count_for_inventory
      return if max_purchase_count >= cached_sales_count_for_inventory

      errors.add(:base, "You have chosen an amount lower than what you have already sold. Please enter an amount greater than #{cached_sales_count_for_inventory}.")
    end

    def apply_price_changes_to_existing_memberships_settings
      if apply_price_changes_to_existing_memberships?
        if !subscription_price_change_effective_date.present?
          errors.add(:base, "Effective date for existing membership price changes must be present")
        elsif subscription_price_change_effective_date_changed? && subscription_price_change_effective_date < MINIMUM_DAYS_TIL_EXISTING_MEMBERSHIP_PRICE_CHANGE.days.from_now.in_time_zone(user.timezone).to_date
          errors.add(:base, "The effective date must be at least 7 days from today")
        end
      end
    end

    def update_product_search_index
      if link.present? && saved_change_to_price_difference_cents?
        link.enqueue_index_update_for(["available_price_cents"])
      end
    end

    def strip_subscription_price_change_message
      unless strip_tags(subscription_price_change_message).present?
        self.subscription_price_change_message = nil
      end
    end
end
