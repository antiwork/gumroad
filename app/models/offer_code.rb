# frozen_string_literal: true

class OfferCode < ApplicationRecord
  has_paper_trail

  include FlagShihTzu
  include ExternalId
  include CurrencyHelper
  include Deletable
  include MaxPurchaseCount
  include OfferCode::Sorting

  has_flags 1 => :is_cancellation_discount,
            2 => :created_via_cli,
            # Keep legacy fixed discounts per-item unless the seller opts into order-level pricing.
            3 => :once_per_cart,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  stripped_fields :code

  has_and_belongs_to_many :products, class_name: "Link", join_table: "offer_codes_products", association_foreign_key: "product_id", after_add: :note_applicability_change, after_remove: [:note_applicability_change, :note_removed_product]
  has_and_belongs_to_many :ownership_products, class_name: "Link", join_table: "offer_codes_ownership_products", association_foreign_key: "product_id"
  has_and_belongs_to_many :excluded_products, class_name: "Link", join_table: "offer_codes_excluded_products", association_foreign_key: "product_id", after_add: [:invalidate_excluded_product_cache, :note_applicability_change], after_remove: [:invalidate_excluded_product_cache, :note_applicability_change]
  belongs_to :user
  has_many :purchases
  has_many :purchases_that_count_towards_offer_code_uses, -> { counts_towards_offer_code_uses }, class_name: "Purchase"
  has_many :purchases_that_count_towards_offer_code_revenue, -> { offer_code_statistics }, class_name: "Purchase"
  has_one :upsell

  alias_attribute :duration_in_billing_cycles, :duration_in_months

  MAX_OWNERSHIP_DURATION_TIERS = 10
  # Enough for the seller to recognise the products without an unbounded message.
  NAMED_DEFAULT_DISCOUNT_PRODUCTS = 3

  # Regex modified from https://stackoverflow.com/a/26900132
  validates :code, presence: true, format: { with: /\A[A-Za-zÀ-ÖØ-öø-ÿ0-9\-_]*\z/, message: "can only contain numbers, letters, dashes, and underscores." }, unless: -> { is_cancellation_discount? || upsell.present? }
  validate :max_purchase_count_is_greater_than_or_equal_to_inventory_sold
  validate :expires_at_is_after_valid_at
  validate :price_validation
  validate :validate_cancellation_discount_uniqueness
  validate :validate_cancellation_discount_product_type
  validate :validate_not_used_as_default_discount
  validate :validate_existing_customer_settings
  validate :validate_ownership_duration_tiers
  validate :validate_excluded_products
  validate :validate_default_discount_remains_applicable


  after_save :invalidate_product_cache
  after_save :reindex_associated_products
  after_save :note_column_applicability_changes
  after_commit :repair_detached_default_discounts, if: -> { @applicability_changed }
  after_rollback :forget_applicability_changes
  before_destroy :capture_associated_product_ids
  after_destroy :reindex_captured_products

  validates_uniqueness_of :code, scope: %i[user_id deleted_at], if: :universal?, unless: :deleted?, message: "must be unique."
  validate :code_validation, unless: lambda { |offer_code| offer_code.deleted? || offer_code.universal? || offer_code.upsell.present? }

  # Public: Scope to get only universal offer codes which is when an offer applies to all user's products.
  # Fixed-amount-off offer codes only show up on products that match their currency. That's why this scope takes a currency_type.
  # nil currency_type is a percentage offer code
  scope :universal_with_matching_currency, ->(currency_type) { where("universal = 1 and (currency_type = ? or currency_type is null)", currency_type) }

  # Public: Search offer codes by name
  scope :search_by_name, ->(query, limit: 20, reverse: false) {
    query = query.to_s.strip.downcase
    return none if query.blank?
    relation = where("LOWER(name) LIKE ?", "%#{query}%").limit(limit)
    reverse ? relation.order(created_at: :desc) : relation.order(created_at: :asc)
  }
  scope :universal, -> { where(universal: true) }
  scope :renewal_eligible, -> { where("existing_customers_only = ? OR JSON_LENGTH(ownership_duration_tiers) > 0", true) }
  scope :not_excluding_product, ->(product) {
    where("NOT EXISTS (SELECT 1 FROM offer_codes_excluded_products WHERE offer_codes_excluded_products.offer_code_id = offer_codes.id AND offer_codes_excluded_products.product_id = ?)", product.id)
  }

  # Codes may contain accented Latin characters (see the format validation above), so NFC-normalize
  # before comparing — a decomposed client submission must match its precomposed stored form. For
  # DB lookups the collation forgives everything here except leading whitespace.
  def self.normalize_code(code)
    code.to_s.unicode_normalize(:nfc).strip.downcase
  end

  def is_valid_for_purchase?(purchase_quantity: 1, excluding_purchase: nil)
    return true if max_purchase_count.nil?

    quantity_left(excluding_purchase:) >= (is_cents? && once_per_cart? ? 1 : purchase_quantity)
  end

  def quantity_left(excluding_purchase: nil, excluding_purchases: nil, excluding_order: nil, excluding_once_per_cart_allocation_ids: nil, lock: false)
    max_purchase_count -
      times_used(excluding_once_per_cart_allocation_ids:, lock:) -
      active_once_per_cart_reservations(
        excluding_purchase:,
        excluding_purchases:,
        excluding_order:,
        excluding_once_per_cart_allocation_ids:,
        lock:
      )
  end

  def is_percent?
    amount_percentage.present?
  end

  def is_cents?
    amount_cents.present?
  end

  def amount_off(price_cents)
    return amount_cents if is_cents?
    return 0 if amount_percentage.nil?

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
        minimum_amount_cents:,
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
      minimum_amount_cents:,
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

  # Batched uses-left for capped codes, preserving the usage mode recorded at checkout.
  def self.uses_left_by_id(codes)
    code_ids = codes.map(&:id)
    purchases = Purchase.counts_towards_offer_code_uses.where(offer_code_id: code_ids)
    per_item = purchases.left_joins(:purchase_offer_code_discount)
                        .where(purchase_offer_code_discounts: { once_per_cart: [false, nil] })
                        .group(:offer_code_id).sum(:quantity)
    legacy_per_cart = purchases.joins(:purchase_offer_code_discount)
                               .where(purchase_offer_code_discounts: { once_per_cart: true, once_per_cart_allocation_id: nil })
                               .group(:offer_code_id).count
    reservations = Purchase.active_once_per_cart_offer_code_reservations
                           .where(offer_code_id: code_ids)
                           .where(purchase_offer_code_discounts: { once_per_cart_allocation_id: nil })
                           .group(:offer_code_id).count
    completed_allocations = Purchase.completed_once_per_cart_allocation_uses.where(offer_code_id: code_ids)
    allocation_uses = completed_allocations.group(:offer_code_id)
                                           .distinct.count("purchase_offer_code_discounts.once_per_cart_allocation_id")
    active_allocations = Purchase.active_once_per_cart_allocation_uses.where(offer_code_id: code_ids)
    allocation_reservations = active_allocations
      .where.not(purchase_offer_code_discounts: {
                   once_per_cart_allocation_id: completed_allocations.select("purchase_offer_code_discounts.once_per_cart_allocation_id")
                 })
      .group(:offer_code_id)
      .distinct.count("purchase_offer_code_discounts.once_per_cart_allocation_id")
    used = per_item.merge(legacy_per_cart) { |_id, item_uses, cart_uses| item_uses + cart_uses }
                   .merge(reservations) { |_id, completed_uses, reserved_uses| completed_uses + reserved_uses }
                   .merge(allocation_uses) { |_id, legacy_uses, allocation_count| legacy_uses + allocation_count }
                   .merge(allocation_reservations) { |_id, completed_uses, reserved_uses| completed_uses + reserved_uses }
    codes.to_h { |code| [code.id, (code.max_purchase_count - used.fetch(code.id, 0)) >= 1] }
  end

  def times_used(excluding_once_per_cart_allocation_ids: nil, lock: false)
    uses = purchases.counts_towards_offer_code_uses
    uses = uses.lock if lock
    per_item = uses.left_joins(:purchase_offer_code_discount)
                   .where(purchase_offer_code_discounts: { once_per_cart: [false, nil] }).sum(:quantity)
    legacy_per_cart = uses.joins(:purchase_offer_code_discount)
                          .where(purchase_offer_code_discounts: { once_per_cart: true, once_per_cart_allocation_id: nil }).count
    allocation_uses = purchases.merge(Purchase.completed_once_per_cart_allocation_uses)
    allocation_uses = allocation_uses.lock if lock
    allocation_uses = allocation_uses.where.not(
      purchase_offer_code_discounts: { once_per_cart_allocation_id: excluding_once_per_cart_allocation_ids }
    ) if excluding_once_per_cart_allocation_ids.present?
    allocation_uses = allocation_uses.distinct.count("purchase_offer_code_discounts.once_per_cart_allocation_id")
    per_item + legacy_per_cart + allocation_uses
  end

  def active_once_per_cart_reservations(excluding_purchase: nil, excluding_purchases: nil, excluding_order: nil, excluding_once_per_cart_allocation_ids: nil, lock: false)
    reservations = purchases.merge(Purchase.active_once_per_cart_offer_code_reservations)
    completed_allocations = purchases.merge(Purchase.completed_once_per_cart_allocation_uses)
    active_allocations = purchases.merge(Purchase.active_once_per_cart_allocation_uses)
    if lock
      reservations = reservations.lock
      completed_allocations = completed_allocations.lock
      active_allocations = active_allocations.lock
    end
    excluded_purchase_ids = Array(excluding_purchases).filter_map { _1.id if _1.persisted? }
    excluded_purchase_ids << excluding_purchase.id if excluding_purchase&.persisted?
    if excluded_purchase_ids.any?
      reservations = reservations.where.not(id: excluded_purchase_ids)
      completed_allocations = completed_allocations.where.not(id: excluded_purchase_ids)
      active_allocations = active_allocations.where.not(id: excluded_purchase_ids)
    end
    if excluding_order&.persisted?
      excluded_purchase_ids = excluding_order.order_purchases.select(:purchase_id)
      reservations = reservations.where.not(id: excluded_purchase_ids)
      completed_allocations = completed_allocations.where.not(id: excluded_purchase_ids)
      active_allocations = active_allocations.where.not(id: excluded_purchase_ids)
    end
    if excluding_once_per_cart_allocation_ids.present?
      excluded_allocations = { purchase_offer_code_discounts: { once_per_cart_allocation_id: excluding_once_per_cart_allocation_ids } }
      completed_allocations = completed_allocations.where.not(excluded_allocations)
      active_allocations = active_allocations.where.not(excluded_allocations)
    end
    legacy_reservations = reservations.where(purchase_offer_code_discounts: { once_per_cart_allocation_id: nil }).count
    allocation_reservations = active_allocations
      .where.not(purchase_offer_code_discounts: {
                   once_per_cart_allocation_id: completed_allocations.select("purchase_offer_code_discounts.once_per_cart_allocation_id")
                 })
      .distinct.count("purchase_offer_code_discounts.once_per_cart_allocation_id")
    legacy_reservations + allocation_reservations
  end

  def auto_delete_if_single_use_exhausted!
    return unless max_purchase_count == 1
    return if deleted?
    return if quantity_left > 0

    mark_deleted!
  end

  def time_fields
    attributes.keys.keep_if { |key| key.include?("_at") && send(key) }
  end

  def applicable_products
    if universal?
      scope = currency_type.present? ? user.links.alive.where(price_currency_type: currency_type) : user.links.alive
      excluded_ids = excluded_product_ids
      excluded_ids.any? ? scope.where.not(id: excluded_ids) : scope
    else
      products
    end
  end

  # The join-table callbacks that record removals fire during assign_attributes,
  # before validation. Clearing here keeps a stale list from an earlier failed
  # save (the object is reused across retries) out of the next validation pass.
  def reload(...)
    @removed_product_ids = nil
    super
  end

  def applicable?(link)
    if universal?
      return false if excluded_products.include?(link)
      currency_type.present? ? link.price_currency_type == currency_type : true
    else
      products.include?(link)
    end
  end

  def inactive?
    !!(valid_at&.future? || expires_at&.past?)
  end

  def discount
    json = (
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
    json[:excluded_product_ids] = excluded_products.map(&:external_id) if universal? && excluded_products.present?
    if is_cents? && once_per_cart?
      json[:once_per_cart] = true
      json[:once_per_cart_id] = external_id
      json[:once_per_cart_amount_cents] = amount_cents
      json[:once_per_cart_has_usage_limit] = max_purchase_count.present?
    end
    json
  end

  def discount_for_display(buyer: nil, product: nil, fallback_purchase: nil)
    return nil if existing_customers_only? && buyer.nil?
    return evaluate_for_buyer(buyer, product:, fallback_purchase:) if buyer.present? || (tiered? && fallback_purchase.present?)

    configured_discount_for_display
  end

  def configured_discount_for_display
    return discount unless tiered?

    percentages = normalized_ownership_duration_tiers.map { _1["amount_percentage"] }
    min_percentage = percentages.min
    max_percentage = percentages.max
    discount.merge(
      type: "percent",
      percents: max_percentage,
      tiered: true,
      min_percents: min_percentage,
      max_percents: max_percentage
    )
  end

  def tiered?
    ownership_duration_tiers.present?
  end

  def normalized_ownership_duration_tiers
    return nil unless tiered?
    ownership_duration_tiers.map do |tier|
      raw = tier.with_indifferent_access
      { "months" => raw["months"].to_i, "amount_percentage" => raw["amount_percentage"].to_i }
    end.sort_by { it["months"] }
  end

  def evaluate_for_buyer(buyer, product: nil, fallback_purchase: nil)
    reference = ownership_reference_products(product)
    months = ownership_months_for(buyer, reference) if existing_customers_only? || tiered?
    return nil if existing_customers_only? && months.nil?

    if tiered?
      months ||= months_since(fallback_purchase&.created_at)
      tier = matching_tier_for(months || 0)
      return nil if tier.nil?
      return discount.merge(type: "percent", percents: tier["amount_percentage"])
    end

    discount
  end

  # A purchase belongs to a buyer either because it is attached to their account
  # (purchases.purchaser_id) or because they bought it as a guest, in which case
  # the purchase only carries the checkout email and purchaser_id stays NULL
  # until the buyer claims it. Both count as ownership here, resolved the same
  # way the buyer's library and community access resolve it — purchaser_id OR
  # the account email (see User#accessible_communities_ids). This path stays
  # stricter about which purchases qualify: the not_* scopes below drop refunded,
  # charged-back, gifted and access-revoked purchases, which the community query
  # does not do.
  #
  # The email leg requires a confirmed account email: an unconfirmed address has
  # not been proven to belong to the signed-in user, so trusting it would let
  # someone sign up with a stranger's email and inherit that stranger's
  # existing-customer discounts.
  def ownership_months_for(buyer, products)
    return nil if buyer.nil?
    return nil if products.blank?

    ownership_condition = if buyer.email.present? && buyer.confirmed?
      ["purchases.purchaser_id = ? OR purchases.email = ?", buyer.id, buyer.email]
    else
      ["purchases.purchaser_id = ?", buyer.id]
    end

    oldest = Purchase
      .all_success_states
      .not_is_additional_contribution
      .not_recurring_charge
      .not_is_gift_sender_purchase
      .not_fully_refunded
      .not_chargedback_or_chargedback_reversed
      .not_is_access_revoked
      .where(link_id: products.map(&:id))
      .where(*ownership_condition)
      .order(:created_at)
      .pick(:created_at)
    months_since(oldest)
  end

  def months_since(timestamp)
    return nil if timestamp.nil?
    now = Time.current
    months = (now.year * 12 + now.month) - (timestamp.year * 12 + timestamp.month)
    months -= 1 if timestamp.advance(months:) > now
    [months, 0].max
  end

  def matching_tier_for(ownership_months)
    return nil unless tiered?
    normalized_ownership_duration_tiers.reverse.find { it["months"] <= ownership_months }
  end

  def is_amount_valid?(product)
    if tiered?
      return normalized_ownership_duration_tiers.all? { is_percentage_amount_valid?(product, it["amount_percentage"]) }
    end

    product.available_price_cents.all? do |unit_price_cents|
      eligible_price_cents = unit_price_cents * once_per_cart_eligible_quantity
      price_after_code = eligible_price_cents - amount_off(eligible_price_cents)
      price_after_code <= 0 || price_after_code >= product.currency["min_price"]
    end
  end

  def self.human_attribute_name(attr, _)
    attr == "code" ? "Discount code" : super
  end

  private
    def ownership_reference_products(product = nil)
      return ownership_products if ownership_products.present?
      return [product] if product
      applicable_products
    end

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
      return errors.add(:base, "Please enter a discount amount.") if !tiered? && !is_percent? && !is_cents?

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

      return if product.available_price_cents.none? do |price_cents|
        eligible_price_cents = price_cents * once_per_cart_eligible_quantity
        eligible_price_cents - amount_off(eligible_price_cents) <= 0
      end

      errors.add(:base, "A fixed-duration discount code cannot be used to make a membership product temporarily free. Please add a free trial to your membership instead.")
    end

    def once_per_cart_eligible_quantity
      is_cents? && once_per_cart? ? [minimum_quantity.to_i, 1].max : 1
    end

    def code_validation
      applicable_products.each do |product|
        if product.product_and_universal_offer_codes.any? { |other| code == other.code && id != other.id }
          errors.add(:base, "Discount code must be unique.")
          return
        end
      end
    end

    def invalidate_product_cache
      products.each(&:invalidate_cache)
    end

    # Consumed at commit by repair_detached_default_discounts. Direct collection
    # mutations (products.delete) never save the owner, so nothing consumes it —
    # they bypass the detachment guards. Change product lists through update.
    def note_applicability_change(_product)
      @applicability_changed = true unless new_record?
    end

    # HABTM has no dirty tracking and the join table already holds the new list
    # by the time validations run, so this is the only record of what THIS edit
    # removed. Rows detached before the guard existed are absent from it, which
    # keeps them from blocking edits that never touched them.
    def note_removed_product(product)
      return if new_record?

      (@removed_product_ids ||= []) << product.id
    end

    def note_column_applicability_changes
      return if previously_new_record?

      @applicability_changed ||= saved_changes.keys.intersect?(%w[universal currency_type deleted_at code])
    end

    def forget_applicability_changes
      @applicability_changed = false
      @removed_product_ids = nil
    end

    # Counterpart of Link#repair_detached_default_offer_code for the other
    # commit order: an edit that validated before a concurrent default
    # assignment landed sweeps its defaulting products after commit. Set-based
    # so a code defaulting many products costs a couple of queries, not one per
    # product; gated to edits that can change applicability.
    # The clearing UPDATE re-runs the detachment predicate, so a product
    # reattached between selection and the write is left alone; the pluck only
    # narrows which rows to attempt.
    def repair_detached_default_discounts
      forget_applicability_changes

      product_ids = Link.visible.where(default_offer_code_id: id).with_detached_default_offer_code.pluck(:id)
      return if product_ids.empty?

      Link.where(id: product_ids).with_detached_default_offer_code.update_all(default_offer_code_id: nil)
      Link.where(id: product_ids).find_each(&:invalidate_cache)
    end

    def invalidate_excluded_product_cache(product)
      product.invalidate_cache
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

    def reindex_associated_products(products_to_reindex: applicable_products + excluded_products)
      # A universal code's applicable set is every alive product, so running the
      # per-product index updates inline after_commit blows the request timeout
      # for large catalogs. Enqueue them as background jobs after the row commits.
      product_ids = products_to_reindex.map(&:id)
      AfterCommitEverywhere.after_commit do
        SendToElasticsearchWorker.perform_bulk(
          product_ids.map { |product_id| [product_id, "update", ["offer_codes"]] }
        )
      end
    end

    def capture_associated_product_ids
      @product_ids_to_reindex = applicable_products.ids
    end

    def reindex_captured_products
      reindex_associated_products(products_to_reindex: Link.where(id: @product_ids_to_reindex)) if @product_ids_to_reindex.present?
    end

    def validate_not_used_as_default_discount
      return unless deleted_at_changed? && deleted_at.present?
      return unless persisted? # Skip validation for new records (id is nil)

      if Link.visible.where(default_offer_code_id: id).exists?
        errors.add(:base, "This discount code is currently set as the default discount for one or more active or archived products. Please remove it from all products before deleting.")
      end
    end

    def validate_existing_customer_settings
      return if deleted_at.present?
      return unless existing_customers_only?

      if ownership_products.empty?
        errors.add(:base, "Pick at least one product the customer must already own.")
      end
    end

    def validate_excluded_products
      return if deleted_at.present?
      return if excluded_products.empty?
      return errors.add(:base, "Products can only be excluded from discounts that apply to all products.") unless universal?
      return unless persisted?

      if Link.visible.where(default_offer_code_id: id, id: excluded_products.map(&:id)).exists?
        errors.add(:base, "This discount code is the default discount for one or more of the excluded products. Please remove it from those products before excluding them.")
      end
    end

    # Blocks code edits that would detach a visible product's default discount:
    # removing the product from a product-specific code, or moving a universal
    # code to a currency the product doesn't use (exclusions are guarded by
    # validate_excluded_products). Scoped to what THIS edit changed — the
    # products it removed, or the currency it is moving away from — so defaults
    # detached before this guard existed never block an unrelated rename or
    # expiry change; Onetime::ClearDetachedDefaultOfferCodes clears those.
    # Not atomic with the Link-side default assignment — a concurrent assignment
    # can slip past both validations; repair_detached_default_discounts sweeps it
    # up after commit.
    def validate_default_discount_remains_applicable
      return if deleted_at.present?
      return unless persisted?

      if universal?
        return if currency_type.nil?
        return unless currency_type_changed?

        blocked = Link.visible.where(default_offer_code_id: id).where.not(price_currency_type: currency_type)
        names = blocked.order(:id).limit(NAMED_DEFAULT_DISCOUNT_PRODUCTS).pluck(:name)
        return if names.empty?

        errors.add(:base, "This discount code is the default discount for #{to_product_sentence(names, blocked.count)}, which #{names.one? ? "uses" : "use"} a different currency. Please remove it from #{names.one? ? "that product" : "those products"} before changing the discount's currency.")
      else
        return if removed_product_ids.empty?

        blocked = Link.visible.where(default_offer_code_id: id, id: removed_product_ids)
        names = blocked.order(:id).limit(NAMED_DEFAULT_DISCOUNT_PRODUCTS).pluck(:name)
        return if names.empty?

        errors.add(:base, "This discount code is the default discount for #{to_product_sentence(names, blocked.count)}. Please remove it from #{names.one? ? "that product" : "those products"} before removing #{names.one? ? "it" : "them"} from the discount.")
      end
    end

    def removed_product_ids
      # A code switching from universal to product-specific removes nothing, but
      # every product defaulting to it that isn't in the new list detaches.
      return Link.visible.where(default_offer_code_id: id).where.not(id: products.map(&:id)).pluck(:id) if universal_changed?(from: true, to: false)
      return [] if @removed_product_ids.blank?

      # Subtract the current list: a product removed and re-added in the same
      # edit is recorded by after_remove but ends up attached, so it detaches
      # nothing.
      @removed_product_ids - products.map(&:id)
    end

    def to_product_sentence(names, total)
      quoted = names.map { "“#{_1}”" }
      remaining = total - names.size
      return quoted.to_sentence if remaining <= 0

      (quoted + ["#{remaining} #{"other".pluralize(remaining)}"]).to_sentence
    end

    def validate_ownership_duration_tiers
      return if deleted_at.present?
      return if ownership_duration_tiers.blank?

      if duration_in_billing_cycles.present?
        errors.add(:base, "Remove the membership duration to use tiered discounts.")
        return
      end

      if is_cents?
        errors.add(:base, "Switch the discount type to percentage to use tiers.")
        return
      end

      tiers = ownership_duration_tiers
      unless tiers.is_a?(Array) && tiers.any?
        errors.add(:base, "Add at least one tier.")
        return
      end

      if tiers.length > MAX_OWNERSHIP_DURATION_TIERS
        errors.add(:base, "Use up to #{MAX_OWNERSHIP_DURATION_TIERS} tiers.")
        return
      end

      raw_tiers = tiers.map(&:with_indifferent_access)

      unless raw_tiers.all? { it["months"].is_a?(Integer) && it["months"] >= 0 }
        errors.add(:base, "Each tier must start at a whole number of months (0 or more).")
        return
      end

      unless raw_tiers.all? { it["amount_percentage"].is_a?(Integer) && (0..100).cover?(it["amount_percentage"]) }
        errors.add(:base, "Each tier percentage must be between 0 and 100.")
        return
      end

      months = raw_tiers.map { it["months"] }
      unless months == months.uniq
        errors.add(:base, "Each tier needs a different starting month.")
        return
      end

      unless months.min.zero?
        errors.add(:base, "The first tier must start at 0 months.")
        return
      end

      applicable_products.each do |product|
        validate_ownership_duration_tier_prices(product, raw_tiers)
        return if errors.present?
      end
    end

    def validate_ownership_duration_tier_prices(product, raw_tiers)
      return if raw_tiers.all? { |tier| is_percentage_amount_valid?(product, tier["amount_percentage"]) }

      errors.add(:base, "The price after discount for all of your products must be either #{product.currency["symbol"]}0 or at least #{product.min_price_formatted}.")
    end

    def is_percentage_amount_valid?(product, amount_percentage)
      product.available_price_cents.all? do |price_cents|
        price_after_code = price_cents - (price_cents * (amount_percentage / 100.0)).round
        price_after_code <= 0 || price_after_code >= product.currency["min_price"]
      end
    end
end
