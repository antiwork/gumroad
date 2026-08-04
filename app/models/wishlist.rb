# frozen_string_literal: true

class Wishlist < ApplicationRecord
  include ExternalId, Deletable, FlagShihTzu
  include Wishlist::StructuredData

  DEFAULT_NAME_MATCHER = /\AWishlist \d+\z/

  # Below this, a wishlist page is too thin to be worth a slot in the index —
  # it gets a noindex robots meta and stays out of the sitemap.
  MINIMUM_SEO_INDEXABLE_PRODUCTS = 3

  belongs_to :user

  has_many :wishlist_products
  has_many :alive_wishlist_products, -> { alive }, class_name: "WishlistProduct"
  has_many :products, through: :wishlist_products
  has_many :wishlist_followers

  has_flags 1 => :discover_opted_out

  validates :name, presence: true
  validates :description, length: { maximum: 3_000 }

  before_save -> { update_recommendable(save: false) }

  def self.find_by_url_slug(url_slug)
    find_by_external_id_numeric(url_slug.split("-").last.to_i)
  end

  # `recommendable` already encodes the discoverability gates (not opted out of
  # Discover, non-default name, non-adult content, has products) — reuse it as
  # the visibility signal and only add the thin-content floor on top.
  def self.seo_indexable
    alive
      .where(recommendable: true)
      .joins(:alive_wishlist_products)
      .group(:id)
      .having("COUNT(DISTINCT wishlist_products.product_id) >= ?", MINIMUM_SEO_INDEXABLE_PRODUCTS)
  end

  # DISTINCT product_id: the same product can appear on a wishlist as several
  # alive rows (per variant/recurrence — see WishlistProduct's uniqueness scope),
  # and the thin-content floor is about distinct products, not rows.
  def seo_indexable?
    recommendable? && alive_wishlist_products.distinct.count(:product_id) >= MINIMUM_SEO_INDEXABLE_PRODUCTS
  end

  def url_slug
    "#{name.parameterize}-#{external_id_numeric}"
  end

  def followed_by?(user)
    wishlist_followers.alive.exists?(follower_user: user)
  end

  def wishlist_products_for_email
    followers_last_contacted_at? ? wishlist_products.alive.where("created_at > ?", followers_last_contacted_at) : wishlist_products.alive
  end

  def update_recommendable(save: true)
    self.recommendable = !discover_opted_out? && name !~ DEFAULT_NAME_MATCHER && !AdultKeywordDetector.adult?(name) && !AdultKeywordDetector.adult?(description) && alive_wishlist_products.any?
    self.save if save
  end
end
