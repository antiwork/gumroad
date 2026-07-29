# frozen_string_literal: true

class Pages::ProfileData
  # Bumped when the shape of the cached payload changes (v4 added products' cover_url,
  # v5 moved product/post URLs onto the seller's live custom domain), so already-cached
  # entries built by the previous shape are not served to pages that now expect the new keys.
  CACHE_VERSION = "v5"
  MAX_ITEMS = 100
  DESCRIPTION_LIMIT = 200

  def self.build(seller)
    # Look the profile up directly rather than via seller.seller_profile, which builds and leaves an
    # unsaved record on the seller to be autosaved later (see User#seller_profile). A seller may have
    # no profile row yet, so every read off this is nil-safe.
    seller_profile = SellerProfile.find_by(seller_id: seller.id)
    Rails.cache.fetch(cache_key(seller, seller_profile)) do
      base_url = seller.store_base_url
      {
        products: products(seller, base_url),
        posts: posts(seller, base_url),
        pages: pages(seller_profile),
      }
    end
  end

  def self.cache_key(seller, seller_profile)
    [
      "profile_data",
      CACHE_VERSION,
      # The cached payload embeds full product and post URLs built from User#store_base_url,
      # so the key must change when either input to that can move: the username, and the
      # custom domain row whose activation or removal flips which host is emitted. Keying on
      # the username itself (rather than the whole user record) avoids rebuilding the cache
      # on unrelated user-row updates.
      seller.username,
      seller.custom_domain&.cache_key_with_version,
      seller.products.cache_key_with_version,
      seller.installments.visible_on_profile.cache_key_with_version,
      seller_profile&.cache_key_with_version,
    ].join("/")
  end

  def self.products(seller, base_url = seller.store_base_url)
    seller.products.alive.not_archived.not_draft
          .includes(:thumbnail_alive, display_asset_previews: { file_attachment: :blob })
          .order(created_at: :desc).limit(MAX_ITEMS).map do |product|
      {
        name: product.name,
        url: product.long_url(host: base_url),
        price: product.price_formatted_verbose,
        native_type: product.native_type,
        thumbnail_url: page_renderable_image_url(product.thumbnail_alive),
        # Most products have no thumbnail but do have a cover image, and a card with no
        # image at all reads as broken. Emitting the cover as a second option lets a page
        # fall back to it (this mirrors Link#thumbnail_or_cover_url, which every other
        # product card in the app already uses).
        cover_url: page_renderable_image_url(first_renderable_cover(product)),
        description: ActionView::Base.full_sanitizer.sanitize(product.description.to_s).squish.truncate(DESCRIPTION_LIMIT),
      }
    end
  end

  # Covers can be videos or embeds as well as images, and only an image can go in an
  # <img> tag, so pick the first one that is actually an image the page can load.
  def self.first_renderable_cover(product)
    product.display_asset_previews.find { |preview| preview.image_url? && preview.unsplash_url.blank? }
  end

  # This payload is injected into seller custom HTML pages, which are served under a
  # strict Content-Security-Policy allowing images only from Gumroad's own asset hosts
  # (see RendersCustomHtmlPages::CUSTOM_HTML_CSP). A thumbnail or cover that lives on
  # Unsplash instead of Gumroad's CDN would be blocked by that policy and render as a
  # broken image, so treat it as absent — the page then falls through to its next
  # option (cover image, then a text-only card) rather than showing a broken one.
  def self.page_renderable_image_url(image)
    return if image.nil? || image.unsplash_url.present?

    image.url
  end

  def self.posts(seller, base_url = seller.store_base_url)
    seller.installments.visible_on_profile.includes(:seller).order(published_at: :desc).limit(MAX_ITEMS).map do |post|
      {
        name: post.name,
        url: post.full_url(host: base_url),
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
