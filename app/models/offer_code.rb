# frozen_string_literal: true

class OfferCode < ApplicationRecord
  has_paper_trail

  include FlagShihTzu
  include ExternalId
  include CurrencyHelper
  include Mongoable
  include Deletable
  include MaxPurchaseCount
  include OfferCode::Sorting

  has_flags 1 => :is_cancellation_discount,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  stripped_fields :code

  has_and_belongs_to_many :products, class_name: "Link", join_table: "offer_codes_products", association_foreign_key: "product_id"
  belongs_to :user, optional: true
  has_many :purchases
  has_many :purchases_that_count_towards_offer_code_uses, -> { counts_towards_offer_code_uses }, class_name: "Purchase"
  has_one :upsell

  alias_attribute :duration_in_billing_cycles, :duration_in_months

  # Regex modified from https://stackoverflow.com/a/26900132
  validates :code, presence: true, format: { with: /\A[A-Za-zÀ-ÖØ-öø-ÿ0-9\-_]*\z/, message: "can only contain numbers, letters, dashes, and underscores." }, unless: -> { is_cancellation_discount? || upsell.present? }
  validate :max_purchase_count_is_greater_than_or_equal_to_inventory_sold
  validate :expires_at_is_after_valid_at
  validate :price_validation
  validate :validate_cancellation_discount_uniqueness
  validate :validate_cancellation_discount_product_type

  before_save :to_mongo

  after_save :invalidate_product_cache

  validates_uniqueness_of :code, scope: %i[user_id deleted_at], if: :universal?, unless: :deleted?, message: "must be unique."
  validate :code_validation, unless: lambda { |offer_code| offer_code.deleted? || offer_code.universal? || offer_code.upsell.present? }

  # Public: Scope to get only universal offer codes which is when an offer applies to all user's products.
  # Fixed-amount-off offer codes only show up on products that match their currency. That's why this scope takes a currency_type.
  # nil currency_type is a percentage offer code
  scope :universal_with_matching_currency, ->(currency_type) { where("universal = 1 and (currency_type = ? or currency_type is null)", currency_type) }
  scope :universal, -> { where(universal: true) }

  def is_valid_for_purchase?(purchase_quantity: 1)
    return true if max_purchase_count.nil?

    quantity_left >= purchase_quantity
  end

  def quantity_left
    max_purchase_count - times_used
  end

  def is_percent?
    amount_percentage.present?
  end

  def is_cents?
    amount_cents.present?
  end

  def amount_off(price_cents)
    return amount_cents if is_cents?

    (price_cents * (amount_percentage / 100.0)).round
  end

  def original_price(discounted_price_cents)
    return if amount_percentage == 100 # cannot determine original price from 100% discount code
    return discounted_price_cents + amount_cents if is_cents?
    (discounted_price_cents / (1 - amount_percentage / 100.0)).round
  end

  def amount
    is_percent? ? amount_percentage : amount_cents
  end

  def is_currency_valid?(product)
    is_percent? || currency_type.nil? || product.price_currency_type == currency_type
  end

  # Return amount buyer got off of the purchase with or without currency/'%'
  #
  # with_symbol - include currency/'%' in returned amount
  def displayed_amount_off(currency_type, with_symbol: false)
    if with_symbol
      return Money.new(amount_cents, currency_type).format(no_cents_if_whole: true, symbol: true) if is_cents?

      "#{amount_percentage}%"
    else
      return MoneyFormatter.format(amount_cents, currency_type.to_sym, no_cents_if_whole: true, symbol: false) if is_cents?

      amount_percentage
    end
  end

  def as_json(options = {})
    if options[:api_scopes].present?
      as_json_for_api
    else
      json = {
        id: external_id,
        code:,
        max_purchase_count:,
        universal: universal?,
        times_used:
      }

      if is_percent?
        json[:percent_off] = amount_percentage
      else
        json[:amount_cents] = amount_cents
      end

      json
    end
  end

  def as_json_for_api
    json = {
      id: external_id,
      # The `code` is returned as `name` for backwards compatibility of the API
      name: code,
      max_purchase_count:,
      universal: universal?,
      times_used:
    }

    if is_percent?
      json[:percent_off] = amount_percentage
    else
      json[:amount_cents] = amount_cents
    end

    json
  end

  def times_used
    purchases.counts_towards_offer_code_uses.sum(:quantity)
  end

  def time_fields
    attributes.keys.keep_if { |key| key.include?("_at") && send(key) }
  end

  def applicable_products
    if universal?
      currency_type.present? ? user.links.alive.where(price_currency_type: currency_type) : user.links.alive
    else
      products
    end
  end

  def applicable?(link)
    if universal?
      currency_type.present? ? link.price_currency_type == currency_type : true
    else
      products.include?(link)
    end
  end

  def inactive?
    !!(valid_at&.future? || expires_at&.past?)
  end

  def discount
    (
      is_cents? ?
        { type: "fixed", cents: amount_cents } :
        { type: "percent", percents: amount_percentage }
    ).merge(
      {
        product_ids: universal? ? nil : products.map(&:external_id),
        expires_at:,
        minimum_quantity:,
        duration_in_billing_cycles:,
        minimum_amount_cents:,
      }
    )
  end

  def is_amount_valid?(product)
    product.available_price_cents.all? do |price_cents|
      price_after_code = price_cents - amount_off(price_cents)
      price_after_code <= 0 || price_after_code >= product.currency["min_price"]
    end
  end

  def self.human_attribute_name(attr, _)
    attr == "code" ? "Discount code" : super
  end

  private
    def max_purchase_count_is_greater_than_or_equal_to_inventory_sold
      return if deleted_at.present?
      return unless max_purchase_count_changed?
      return if max_purchase_count.nil? || max_purchase_count >= times_used

      errors.add(:base, "You have chosen a discount code quantity that is less that the number already used. Please enter an amount no less than #{times_used}.")
    end

    def expires_at_is_after_valid_at
      if (valid_at.present? && expires_at.present? && expires_at <= valid_at) || (valid_at.blank? && expires_at.present?)
        errors.add(:base, "The discount code's start date must be earlier than its end date.")
      end
    end

    def price_validation
      return if deleted_at.present?
      return errors.add(:base, "Please enter a positive discount amount.") if (is_percent? && amount_percentage.to_i < 0) || (is_cents? && amount_cents.to_i < 0)

      return errors.add(:base, "Please enter a discount amount that is 100% or less.") if is_percent? && amount_percentage > 100

      applicable_products.each do |product|
        validate_price_after_discount(product)
        validate_membership_price_after_discount(product)
        validate_currency_type_after_discount(product)
        return if errors.present?
      end
    end

    def validate_price_after_discount(product)
      return if is_amount_valid?(product)

      errors.add(:base, "The price after discount for all of your products must be either #{product.currency["symbol"]}0 or at least #{product.min_price_formatted}.")
    end

    def validate_currency_type_after_discount(product)
      return if is_currency_valid?(product)

      errors.add(:base, "This discount code uses #{currency_type.upcase} but the product uses #{product.price_currency_type.upcase}. Please change the discount code to use the same currency as the product.")
    end

    def validate_membership_price_after_discount(product)
      return unless product.is_tiered_membership? && duration_in_billing_cycles.present?

      return if product.available_price_cents.none? { _1 - amount_off(_1) <= 0 }
      errors.add(:base, "A fixed-duration discount code cannot be used to make a membership product temporarily free. Please add a free trial to your membership instead.")
    end

    def code_validation
      applicable_products.each do |product|
        if product.product_and_universal_offer_codes.reject { |other| other.id == id }.any? { |other| code == other.code }
          errors.add(:base, "Discount code must be unique.")
          return
        end
      end
    end

    def invalidate_product_cache
      products.each(&:invalidate_cache)
    end

    def validate_cancellation_discount_uniqueness
      return unless is_cancellation_discount?

      if universal?
        errors.add(:base, "Cancellation discount offer codes cannot be universal")
        return
      end

      if products.count > 1
        errors.add(:base, "Cancellation discount offer codes must belong to exactly one product")
        return
      end

      product = products.first
      if product.offer_codes.alive.is_cancellation_discount.where.not(id: id).exists?
        errors.add(:base, "This product already has a cancellation discount offer code")
      end
    end

    def validate_cancellation_discount_product_type
      return unless is_cancellation_discount?

      product = products.first
      unless product.is_tiered_membership?
        errors.add(:base, "Cancellation discounts can only be added to memberships")
      end
    end
end
