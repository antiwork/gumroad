# frozen_string_literal: true

class Wishlist < ApplicationRecord
  include ExternalId, Deletable, FlagShihTzu

  DEFAULT_NAME_MATCHER = /\AWishlist \d+\z/

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
