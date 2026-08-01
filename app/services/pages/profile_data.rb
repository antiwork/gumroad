# frozen_string_literal: true

class Pages::ProfileData
  # Bumped when the shape of the cached payload changes (v5 added the *_total counts and
  # moved product/post URLs onto the seller's live custom domain), so already-cached entries
  # built by the previous shape are not served to pages that now expect the new keys.
  #
  # v6 is a cap change rather than a shape change, and it needs the same bump: the rest of the
  # key is derived from the seller's own rows, so a seller who does not touch a product or post
  # would keep being served the 100-item entry built before MAX_ITEMS was raised.
  CACHE_VERSION = "v6"
  # Raised from 100 (gumroad-private#1522). The population that matters is sellers who actually
  # render a custom profile page, not all sellers: measured on production over the 2,791 with root
  # custom HTML, 100 truncates 16 of them and 200 truncates 2. Pages::ProductPrices — the uncached
  # per-request half — shares this cap, so the ceiling bounds that work too.
  MAX_ITEMS = 200
  DESCRIPTION_LIMIT = 200

  def self.build(seller)
    # Look the profile up directly rather than via seller.seller_profile, which builds and leaves an
    # unsaved record on the seller to be autosaved later (see User#seller_profile). A seller may have
    # no profile row yet, so every read off this is nil-safe.
    seller_profile = SellerProfile.find_by(seller_id: seller.id)
    base_url = seller.store_host_with_protocol
    Rails.cache.fetch(cache_key(seller, seller_profile, base_url)) do
      {
        products: products(seller, base_url),
        posts: posts(seller, base_url),
        pages: pages(seller_profile),
        # A page has no way to discover what MAX_ITEMS dropped: CUSTOM_HTML_CSP sets
        # connect-src 'none', so this payload is its only product source. Emitting the
        # true totals lets a page say "showing 200 of 275" instead of silently
        # advertising an incomplete catalogue (gumroad-private#1522).
        products_total: products_total(seller),
        posts_total: posts_total(seller),
      }
    end
  end

  def self.cache_key(seller, seller_profile, base_url = seller.store_host_with_protocol)
    [
      "profile_data",
      CACHE_VERSION,
      # Certificate validity can lapse without a DB write, so key on the emitted host rather
      # than the custom-domain row's version.
      seller.username,
      base_url,
      seller.products.cache_key_with_version,
      seller.installments.visible_on_profile.cache_key_with_version,
      seller_profile&.cache_key_with_version,
    ].join("/")
  end

  def self.products(seller, base_url = seller.store_host_with_protocol)
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

  def self.products_total(seller)
    seller.products.alive.not_archived.not_draft.count
  end

  def self.posts_total(seller)
    seller.installments.visible_on_profile.count
  end

  def self.posts(seller, base_url = seller.store_host_with_protocol)
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
