# frozen_string_literal: true

module WithFiltering
  extend ActiveSupport::Concern
  include CurrencyHelper, JsonData

  AUDIENCE_TYPE = "audience"
  SELLER_TYPE = "seller"
  PRODUCT_TYPE = "product"
  VARIANT_TYPE = "variant"
  FOLLOWER_TYPE = "follower"
  AFFILIATE_TYPE = "affiliate"
  ABANDONED_CART_TYPE = "abandoned_cart"

  included do
    attr_json_data_accessor :variant
    attr_json_data_accessor :bought_products
    attr_json_data_accessor :not_bought_products
    attr_json_data_accessor :paid_more_than_cents
    attr_json_data_accessor :paid_less_than_cents
    attr_json_data_accessor :created_after
    attr_json_data_accessor :created_before
    attr_json_data_accessor :bought_from
    attr_json_data_accessor :bought_variants
    attr_json_data_accessor :not_bought_variants
    attr_json_data_accessor :affiliate_products

    # Name of the column containing the recipient type.
    # i.e. "installment_type" (Installment) and "workflow_type" (Workflow)
    mattr_reader :recipient_type_column, default: "#{model_name.singular}_type"

    scope :audience_type, -> { where(recipient_type_column => AUDIENCE_TYPE) }
    scope :seller_type, -> { where(recipient_type_column => SELLER_TYPE) }
    scope :product_type, -> { where(recipient_type_column => PRODUCT_TYPE) }
    scope :variant_type, -> { where(recipient_type_column => VARIANT_TYPE) }
    scope :follower_type, -> { where(recipient_type_column => FOLLOWER_TYPE) }
    scope :affiliate_type, -> { where(recipient_type_column => AFFILIATE_TYPE) }
    scope :abandoned_cart_type, -> { where(recipient_type_column => ABANDONED_CART_TYPE) }
    scope :product_or_variant_type, -> { where(recipient_type_column => [PRODUCT_TYPE, VARIANT_TYPE]) }
    scope :seller_or_audience_type, -> { where(recipient_type_column => [SELLER_TYPE, AUDIENCE_TYPE]) }
    scope :follower_or_audience_type, -> { where(recipient_type_column => [FOLLOWER_TYPE, AUDIENCE_TYPE]) }
    scope :affiliate_or_audience_type, -> { where(recipient_type_column => [AFFILIATE_TYPE, AUDIENCE_TYPE]) }
    scope :seller_or_product_or_variant_type, -> { where(recipient_type_column => [SELLER_TYPE, PRODUCT_TYPE, VARIANT_TYPE]) }
  end

  def audience_type? = attributes[self.recipient_type_column] == AUDIENCE_TYPE
  def seller_type? = attributes[self.recipient_type_column] == SELLER_TYPE
  def product_type? = attributes[self.recipient_type_column] == PRODUCT_TYPE
  def variant_type? = attributes[self.recipient_type_column] == VARIANT_TYPE
  def follower_type? = attributes[self.recipient_type_column] == FOLLOWER_TYPE
  def affiliate_type? = attributes[self.recipient_type_column] == AFFILIATE_TYPE
  def abandoned_cart_type? = attributes[self.recipient_type_column] == ABANDONED_CART_TYPE
  def product_or_variant_type? = product_type? || variant_type?
  def seller_or_product_or_variant_type? = seller_type? || product_or_variant_type?

  def add_and_validate_filters(params, user)
    currency = user.currency_type

    self.paid_more_than_cents = if seller_or_product_or_variant_type?
      if params[:paid_more_than_cents].present?
        params[:paid_more_than_cents]
      elsif params[:paid_more_than].present?
        get_usd_cents(currency, (params[:paid_more_than].to_f * unit_scaling_factor(currency)).to_i)
      end
    end
    self.paid_less_than_cents = if seller_or_product_or_variant_type?
      if params[:paid_less_than_cents].present?
        params[:paid_less_than_cents]
      elsif params[:paid_less_than].present?
        get_usd_cents(currency, (params[:paid_less_than].to_f * unit_scaling_factor(currency)).to_i)
      end
    end
    self.bought_products = (!audience_type? && params[:bought_products].present?) ? Array.wrap(params[:bought_products]) : []
    self.not_bought_products = params[:not_bought_products].present? ? Array.wrap(params[:not_bought_products]) : []
    # created "on and after" this timestamp:
    self.created_after = params[:created_after].present? ? Date.parse(params[:created_after]).in_time_zone(user.timezone) : nil
    # created "on and before" this timestamp:
    self.created_before = params[:created_before].present? ? Date.parse(params[:created_before]).in_time_zone(user.timezone).end_of_day : nil
    self.bought_from = seller_or_product_or_variant_type? ? params[:bought_from].presence : nil
    self.bought_variants = (!audience_type? && params[:bought_variants].present?) ? Array.wrap(params[:bought_variants]) : []
    self.not_bought_variants = params[:not_bought_variants].present? ? Array.wrap(params[:not_bought_variants]) : []
    self.affiliate_products = (!audience_type? && params[:affiliate_products].present?) ? Array.wrap(params[:affiliate_products]) : []
    self.workflow_trigger = seller_or_product_or_variant_type? ? params[:workflow_trigger].presence : nil

    if paid_more_than_cents.present? && paid_less_than_cents.present? && paid_more_than_cents > paid_less_than_cents
      errors.add(:base, "Please enter valid paid more than and paid less than values.")
      return false
    end

    if created_after.present? && created_before.present? && created_after > created_before
      errors.add(:base, "Please enter valid before and after dates.")
      return false
    end

    true
  end

  def affiliate_passes_filters(affiliate)
    return false if created_after.present? && affiliate.created_at < created_after
    return false if created_before.present? && affiliate.created_at > created_before
    return false if affiliate_products.present? && (affiliate_products & affiliate.products.pluck(:unique_permalink)).empty?
    true
  end

  def follower_passes_filters(follower)
    return false if created_after.present? && follower.created_at < created_after
    return false if created_before.present? && follower.created_at > created_before
    true
  end

  def purchase_passes_filters(purchase)
    params = purchase.slice(:email, :country, :ip_country)
    params[:min_created_at] = purchase.created_at
    params[:max_created_at] = purchase.created_at
    params[:min_price_cents] = purchase.price_cents
    params[:max_price_cents] = purchase.price_cents
    params[:product_permalinks] = [purchase.link.unique_permalink]
    params[:variant_external_ids] = purchase.variant_attributes.map(&:external_id)

    seller_post_passes_filters(**params.symbolize_keys)
  end

  def seller_post_passes_filters(email: nil, min_created_at: nil, max_created_at: nil, min_price_cents: nil, max_price_cents: nil, country: nil, ip_country: nil, product_permalinks: [], variant_external_ids: [])
    return false if created_after.present? && (min_created_at.nil? || (min_created_at.present? && min_created_at < created_after))
    return false if created_before.present? && (max_created_at.nil? || (max_created_at.present? && max_created_at > created_before))
    excludes_product = bought_products.present? && (product_permalinks.empty? || (bought_products & product_permalinks).empty?)
    excludes_variants = bought_variants.present? && (variant_external_ids.empty? || (bought_variants & variant_external_ids).empty?)
    if bought_products.present? && bought_variants.present?
      return false if excludes_product && excludes_variants
    elsif bought_products.present?
      return false if excludes_product
    elsif bought_variants.present?
      return false if excludes_variants
    end

    return false if paid_more_than_cents.present? && (min_price_cents.nil? || (min_price_cents.present? && min_price_cents < paid_more_than_cents))
    return false if paid_less_than_cents.present? && (max_price_cents.nil? || (max_price_cents.present? && max_price_cents > paid_less_than_cents))
    return false if bought_from.present? && !(country == bought_from || (country.nil? && ip_country == bought_from))

    exclude_product_ids = not_bought_products.present? ? Link.find_by(unique_permalink: not_bought_products)&.id : []
    return false if (exclude_product_ids.present? || not_bought_variants.present?) &&
      seller.sales
            .not_is_archived_original_subscription_purchase
            .not_subscription_or_original_purchase
            .by_external_variant_ids_or_products(not_bought_variants, exclude_product_ids)
            .exists?(email:)

    true
  end

  def json_filters
    json = {}
    json[:bought_products] = bought_products if bought_products.present?
    json[:not_bought_products] = not_bought_products if not_bought_products.present?
    json[:not_bought_variants] = not_bought_variants if not_bought_variants.present?
    json[:bought_variants] = bought_variants if bought_variants.present?
    if paid_more_than_cents.present?
      json[:paid_more_than] = Money.new(paid_more_than_cents, seller.currency_type)
                                   .format(no_cents_if_whole: true, symbol: false)
    end
    if paid_less_than_cents.present?
      json[:paid_less_than] = Money.new(paid_less_than_cents, seller.currency_type)
                                   .format(no_cents_if_whole: true, symbol: false)
    end
    json[:created_after] = convert_to_date(created_after) if created_after.present?
    json[:created_before] = convert_to_date(created_before) if created_before.present?
    json[:bought_from] = bought_from if bought_from.present?
    json[:affiliate_products] = affiliate_products if affiliate_products.present?
    json[:workflow_trigger] = workflow_trigger if workflow_trigger.present?
    json
  end

  def convert_to_date(date)
    date.is_a?(String) ? Date.parse(date) : date
  end
end
