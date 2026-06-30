# frozen_string_literal: true

class Pages::ProfileData
  CACHE_VERSION = "v2"
  MAX_ITEMS = 100
  DESCRIPTION_LIMIT = 200

  def self.build(seller)
    # Look the profile up directly rather than via seller.seller_profile, which builds and leaves an
    # unsaved record on the seller to be autosaved later (see User#seller_profile). A seller may have
    # no profile row yet, so every read off this is nil-safe.
    seller_profile = SellerProfile.find_by(seller_id: seller.id)
    Rails.cache.fetch(cache_key(seller, seller_profile)) do
      {
        products: products(seller),
        posts: posts(seller),
        pages: pages(seller_profile),
      }
    end
  end

  def self.cache_key(seller, seller_profile)
    [
      "profile_data",
      CACHE_VERSION,
      seller.products.cache_key_with_version,
      seller.installments.visible_on_profile.cache_key_with_version,
      seller_profile&.cache_key_with_version,
    ].join("/")
  end

  def self.products(seller)
    seller.products.alive.not_archived.not_draft.includes(:thumbnail_alive).order(created_at: :desc).limit(MAX_ITEMS).map do |product|
      {
        name: product.name,
        url: product.long_url,
        price: product.price_formatted_verbose,
        native_type: product.native_type,
        thumbnail_url: product.thumbnail_alive&.url,
        description: ActionView::Base.full_sanitizer.sanitize(product.description.to_s).squish.truncate(DESCRIPTION_LIMIT),
      }
    end
  end

  def self.posts(seller)
    seller.installments.visible_on_profile.includes(:seller).order(published_at: :desc).limit(MAX_ITEMS).map do |post|
      {
        name: post.name,
        url: post.full_url,
        published_at: post.published_at&.iso8601,
      }
    end
  end

  def self.pages(seller_profile)
    (seller_profile&.json_data&.dig("tabs") || []).filter_map do |tab|
      { name: tab["name"] } if tab["name"].present?
    end
  end
end
