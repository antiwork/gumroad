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

  def visible_cart_products
    alive_cart_products.joins(:product).merge(Link.not_archived).order(created_at: :desc)
  end

  # Product ids in this cart whose recipient has already bought and kept the product.
  #
  # These have to be excluded when an abandoned-cart email is sent: checkout retires only
  # the one cart `fetch_by` resolves, so every *other* alive cart the same buyer holds keeps
  # its products forever and stays eligible on staleness alone. The email then reads as an
  # unfinished order to someone who already paid, and they write in asking whether they were
  # charged twice (gumroad-private#1626 — 26% of a live 2,000-send sample).
  #
  # Gift purchases are read from the owner's side: the sender bought it for someone else and
  # can still legitimately be reminded, while a giftee's own row is not treated as ownership
  # here because the exclusion exists to protect people who paid.
  def purchased_product_ids
    self.class.purchased_product_ids_by_cart_id([self])[id] || []
  end

  # { cart_id => [purchased product ids] } for the given carts, with a bounded number of
  # queries regardless of how many carts are passed. An abandoned-cart run walks every alive
  # cart on the platform, so a per-cart query here would add a round trip per cart to a loop
  # that already had to be rewritten to stay inside MySQL's statement budget
  # (gumroad-private#1198).
  #
  # Recipients are looked up in two separate statements rather than one `email OR purchaser_id`
  # query: an OR across two columns denies the optimizer either single-column index, and both
  # `index_purchases_on_email_long` and `index_purchases_on_purchaser_id` matter at this size.
  def self.purchased_product_ids_by_cart_id(carts)
    product_ids = carts.flat_map { _1.alive_cart_products.map(&:product_id) }.uniq
    return {} if product_ids.empty?

    emails = carts.flat_map { recipient_emails_for(_1) }.uniq
    user_ids = carts.filter_map(&:user_id).uniq
    scope = Purchase.where(link_id: product_ids)
      .successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback
      .not_is_gift_sender_purchase
    rows = []
    rows.concat(scope.where(email: emails).pluck(:link_id, :email, :purchaser_id)) if emails.any?
    rows.concat(scope.where(purchaser_id: user_ids).pluck(:link_id, :email, :purchaser_id)) if user_ids.any?
    return {} if rows.empty?

    carts.each_with_object({}) do |cart, result|
      cart_emails = recipient_emails_for(cart)
      cart_product_ids = cart.alive_cart_products.map(&:product_id)
      result[cart.id] = rows.filter_map do |link_id, purchase_email, purchaser_id|
        next unless cart_product_ids.include?(link_id)
        next unless cart_emails.include?(purchase_email&.downcase) || (cart.user_id.present? && purchaser_id == cart.user_id)

        link_id
      end.uniq
    end
  end

  # Downcased so a purchase made under a differently-cased spelling of the same address still
  # counts — MySQL's collation ignores case in the query above, Ruby's comparison does not.
  def self.recipient_emails_for(cart)
    [cart.email, cart.user&.email].compact_blank.map(&:downcase).uniq
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
