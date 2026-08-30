# frozen_string_literal: true

class Cart < ApplicationRecord
  include SecureExternalId
  include Deletable

  DISCOUNT_CODES_SCHEMA = {
    "$schema": "http://json-schema.org/draft-06/schema#",
    type: "array",
    items: { "$ref": "#/$defs/discount_code" },
    "$defs": {
      discount_code: {
        type: "object",
        properties: {
          code: { type: "string" },
          fromUrl: { type: "boolean" },
        },
        required: [:code, :fromUrl]
      },
    }
  }.freeze

  ABANDONED_IF_UPDATED_AFTER_AGO = 1.month
  ABANDONED_IF_UPDATED_BEFORE_AGO = 24.hours
  MAX_ALLOWED_CART_PRODUCTS = 50

  # Bound on SQL IN-list length, matching ScheduleAbandonedCartEmailsJob: past roughly 10k ids
  # MySQL's range optimizer exhausts range_optimizer_max_mem_size and silently falls back to a
  # full table scan. A 500-cart batch can hold 25k distinct products (MAX_ALLOWED_CART_PRODUCTS
  # each), which is well over that cliff.
  PURCHASE_LOOKUP_IN_LIST_BATCH_SIZE = 5_000

  # Statement budget for the ownership lookup. Sized for the single cart the mailer asks about,
  # which is milliseconds of work. A budget generous enough to cover a bulk caller is what let one
  # pathological statement run long enough to kill a whole abandoned-cart run (gumroad-private#2343).
  # Exceeding it now costs one email, which retries.
  PURCHASE_LOOKUP_TIME_BUDGET = 30.seconds

  belongs_to :user, optional: true
  belongs_to :order, optional: true

  has_many :cart_products
  has_many :alive_cart_products, -> { alive }, class_name: "CartProduct"
  has_many :products, through: :cart_products
  has_many :sent_abandoned_cart_emails

  scope :abandoned, ->(updated_at: ABANDONED_IF_UPDATED_AFTER_AGO.ago.beginning_of_day..ABANDONED_IF_UPDATED_BEFORE_AGO.ago) do
    alive
    .where(updated_at:)
    .left_outer_joins(:sent_abandoned_cart_emails)
    .where(sent_abandoned_cart_emails: { id: nil })
    .where(id: CartProduct.alive.select(:cart_id))
  end

  after_initialize :assign_default_discount_codes

  validate :ensure_discount_codes_conform_to_schema
  validate :ensure_only_one_alive_cart_per_user, on: :create

  def abandoned?
    alive? && updated_at >= ABANDONED_IF_UPDATED_AFTER_AGO.ago.beginning_of_day && updated_at <= ABANDONED_IF_UPDATED_BEFORE_AGO.ago && sent_abandoned_cart_emails.none? && alive_cart_products.exists?
  end

  # The id tiebreak is load-bearing: this order decides which lines a capped discount code covers,
  # and two products added in the same tick would otherwise swap winners between reloads.
  def visible_cart_products
    alive_cart_products.joins(:product).merge(Link.not_archived).order(created_at: :desc, id: :desc)
  end

  # Product ids in this cart whose recipient already owns the product.
  #
  # These have to be excluded when an abandoned-cart email is sent: checkout retires only
  # the one cart `fetch_by` resolves, so every *other* alive cart the same buyer holds keeps
  # its products forever and stays eligible on staleness alone. The email then reads as an
  # unfinished order to someone who already paid, and they write in asking whether they were
  # charged twice (gumroad-private#1626 — 26% of a live 2,000-send sample).
  def purchased_product_ids
    self.class.purchased_product_ids_by_cart_id([self])[id] || []
  end

  # { cart_id => [owned product ids] } for the given carts, in a bounded number of queries
  # regardless of how many carts are passed.
  #
  # Production passes exactly one cart (see #purchased_product_ids). Do not reintroduce a bulk
  # caller: batching widens each statement to the union of every buyer's purchase history, and one
  # heavy buyer then blows the budget for everyone in the batch (gumroad-private#2343).
  def self.purchased_product_ids_by_cart_id(carts)
    product_ids = carts.flat_map { _1.alive_cart_products.map(&:product_id) }.uniq
    return {} if product_ids.empty?

    emails = carts.flat_map { recipient_emails_for(_1) }.uniq
    user_ids = carts.filter_map(&:user_id).uniq
    owned_by_email, owned_by_purchaser = owned_variant_ids_by_recipient(product_ids, emails, user_ids)
    return {} if owned_by_email.empty? && owned_by_purchaser.empty?

    carts.each_with_object({}) do |cart, result|
      owned = recipient_emails_for(cart).filter_map { owned_by_email[_1] }
      owned << owned_by_purchaser[cart.user_id] if cart.user_id.present? && owned_by_purchaser.key?(cart.user_id)

      result[cart.id] = cart.alive_cart_products.filter_map do |cart_product|
        owned_variant_ids = owned.filter_map { _1[cart_product.product_id] }
        next if owned_variant_ids.empty?
        # A carted variant is only owned when a purchase carries that same variant — owning
        # tier A is not owning tier B, and the job's workflow matching is variant-aware for
        # the same reason. A purchase with no variant recorded suppresses nothing here.
        next if cart_product.option_id.present? && owned_variant_ids.none? { _1.include?(cart_product.option_id) }

        cart_product.product_id
      end.uniq
    end
  end

  # Only the address CustomerMailer#abandoned_cart actually delivers to. A logged-in cart can
  # still carry a stale `email` from a guest session, and that address may belong to someone
  # else entirely — counting their purchases here would suppress a reminder the account holder
  # should get. Keep this expression identical to the mailer's `to:`.
  #
  # Downcased so a purchase made under a differently-cased spelling of the same address still
  # counts — Purchase downcases on write and MySQL's collation ignores case, but the Ruby-side
  # comparison below does not, and User#email is not normalized.
  def self.recipient_emails_for(cart)
    [cart.user&.email.presence || cart.email].compact_blank.map(&:downcase).uniq
  end

  # Two maps of { recipient => { product_id => Set(owned variant ids) } }, keyed by downcased
  # email and by purchaser id. Recipients are looked up in separate statements rather than one
  # `email OR purchaser_id` query: an OR across two columns denies the optimizer either
  # single-column index, and both index_purchases_on_email_long and
  # index_purchases_on_purchaser_id matter at this size.
  def self.owned_variant_ids_by_recipient(product_ids, emails, user_ids)
    by_email = {}
    by_purchaser = {}
    WithMaxExecutionTime.timeout_queries(seconds: PURCHASE_LOOKUP_TIME_BUDGET) do
      product_ids.each_slice(PURCHASE_LOOKUP_IN_LIST_BATCH_SIZE) do |batch_product_ids|
        scope = owned_purchases(batch_product_ids)
        collect_owned_variant_ids(scope.where(email: emails), by_email) { _2&.downcase } if emails.any?
        collect_owned_variant_ids(scope.where(purchaser_id: user_ids), by_purchaser) { _3 } if user_ids.any?
      end
    end
    [by_email, by_purchaser]
  end

  # A purchase counts as ownership when the recipient has the product and kept it. Gift SENDER
  # rows do not count (they bought it for someone else and can still be reminded), gift
  # RECEIVER rows do (the product is in their library, so the reminder reads just as wrong).
  # An active free trial counts for the same reason: they have access and a card on file, so
  # "you left this in your cart" is exactly the message that makes them ask whether they were
  # charged. A deactivated subscription does not — the row stays successful forever, and
  # without this a lapsed member could never be reminded about that membership again.
  def self.owned_purchases(product_ids)
    Purchase.where(link_id: product_ids)
      .where(
        "purchases.purchase_state IN (:owned_states) OR " \
        "(purchases.purchase_state = 'not_charged' AND purchases.flags & :free_trial != 0)",
        owned_states: %w[successful preorder_authorization_successful gift_receiver_purchase_successful],
        free_trial: Purchase.flag_mapping["flags"][:is_free_trial_purchase]
      )
      .not_fully_refunded
      .not_chargedback_or_chargedback_reversed
      .not_is_gift_sender_purchase
      .where(
        "purchases.subscription_id IS NULL OR NOT EXISTS (#{Subscription.where("subscriptions.id = purchases.subscription_id").where.not(deactivated_at: nil).select("1").to_sql})"
      )
  end

  # Groups rows into { key => { product_id => Set(variant ids) } }. The left join means one row
  # per purchase-variant pair, and a purchase with no variant yields a NULL that is dropped.
  def self.collect_owned_variant_ids(scope, into)
    scope
      .left_joins(:base_variants_purchases)
      .distinct
      .pluck(:link_id, :email, :purchaser_id, "base_variants_purchases.base_variant_id")
      .each do |link_id, email, purchaser_id, variant_id|
        key = yield(link_id, email, purchaser_id)
        next if key.blank?

        variants = (into[key] ||= {})
        owned = (variants[link_id] ||= Set.new)
        owned << variant_id if variant_id.present?
      end
  end

  def self.fetch_by(user:, browser_guid:)
    return user.carts.alive.first if user.present?
    alive.find_by(browser_guid:, user: nil) if browser_guid.present?
  end

  private
    def assign_default_discount_codes
      self.discount_codes = [] if discount_codes.nil?
    end

    def ensure_discount_codes_conform_to_schema
      JSON::Validator.fully_validate(DISCOUNT_CODES_SCHEMA, discount_codes).each { errors.add(:discount_codes, _1) }
    end

    def ensure_only_one_alive_cart_per_user
      if self.class.fetch_by(user:, browser_guid:).present?
        errors.add(:base, "An alive cart already exists")
      end
    end
end
