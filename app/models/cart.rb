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

  # The distinct sellers whose products are in this cart, as the buyer sees the cart.
  #
  # Scoped to match CartPresenter#cart_props exactly — alive cart rows joined to products that are
  # not archived. The two must agree: if this counted a row the page hides, a cart the buyer sees as
  # one seller's would be treated as mixed (and vice versa), so branding would appear or vanish with
  # no visible cause.
  #
  # `distinct.pluck` rather than loading the products: this runs on every checkout page render and
  # only the seller ids are needed, so it stays a single narrow query no matter how many products
  # are in the cart (the cap is MAX_ALLOWED_CART_PRODUCTS).
  def visible_seller_ids
    alive_cart_products.joins(:product).merge(Link.not_archived).distinct.pluck("links.user_id")
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
