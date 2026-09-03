# frozen_string_literal: true

class Pages::ProfileData
  # Bumped when the shape of the cached payload changes (v5 added the *_total counts and
  # moved product/post URLs onto the seller's live custom domain; v6 added seller_rating;
  # v7 added the id tiebreaker to the product ordering so offset-based slices can't overlap
  # on created_at ties), so already-cached entries built by the previous shape are not served
  # to pages that now expect the new keys.
  CACHE_VERSION = "v7"
  MAX_ITEMS = 100
  DESCRIPTION_LIMIT = 200
  # Intentional on every seller: a cheap rebuild vs pinning any key gap
  # (known case: lost Redis INCR of the reputation version). Stacks with
  # User::ReputationSummary::CACHE_TTL on seller_rating.
  CACHE_TTL = 10.minutes

  def self.build(seller)
    # Look the profile up directly rather than via seller.seller_profile, which builds and leaves an
    # unsaved record on the seller to be autosaved later (see User#seller_profile). A seller may have
    # no profile row yet, so every read off this is nil-safe.
    seller_profile = SellerProfile.find_by(seller_id: seller.id)
    base_url = seller.store_host_with_protocol
    Rails.cache.fetch(cache_key(seller, seller_profile, base_url), expires_in: CACHE_TTL) do
      {
        products: products(seller, base_url),
        posts: posts(seller, base_url),
        pages: pages(seller_profile),
        # A page has no way to discover what MAX_ITEMS dropped: CUSTOM_HTML_CSP sets
        # connect-src 'none', so this payload is its only product source. Emitting the
        # true totals lets a page say "showing 100 of 114" instead of silently
        # advertising an incomplete catalogue (gumroad-private#1522).
        products_total: products_total(seller),
        posts_total: posts_total(seller),
        # Omitted rather than nil when gated off, matching ProfilePresenter and
        # ProductProps, so a seller without the flag gets a byte-identical payload.
        # Present-but-nil still happens when the flag is on and the seller misses
        # the display thresholds; a page treats absent and nil identically.
        **(seller.reputation_summary_enabled? ? { seller_rating: seller.seller_reputation_summary } : {}),
      }
    end
  end

  # One slice of the products array for the gumroad:products bridge (gumroad-private#1691),
  # cached under the same version as the full payload so a slice and page 1 can never describe
  # two different catalogues. products_total rides along on every slice — it's what tells a
  # page how many more requests to make, and it's already part of the cache key's freshness
  # domain (seller.products.cache_key_with_version moves whenever the count does).
  def self.products_page(seller, offset:, limit:)
    seller_profile = SellerProfile.find_by(seller_id: seller.id)
    base_url = seller.store_host_with_protocol
    Rails.cache.fetch([cache_key(seller, seller_profile, base_url), "products", offset, limit].join("/"), expires_in: CACHE_TTL) do
      {
        products: products(seller, base_url, offset:, limit:),
        products_total: products_total(seller),
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
      # Review writes touch product_review_stats, not links, so the products key
      # above never moves when a rating lands; the flag state and this version
      # (a Redis GET, bumped by the review-stat write funnel) keep the cached
      # seller_rating honest.
      seller.reputation_summary_enabled?,
      seller.reputation_summary_enabled? ? seller.reputation_summary_cache_signature : nil,
    ].join("/")
  end

  def self.products(seller, base_url = seller.store_host_with_protocol, offset: 0, limit: MAX_ITEMS)
    # created_at has second precision, so bulk-created products tie; without the id tiebreaker
    # two offset slices could overlap or skip a row at their boundary. Pages::ProductPrices
    # must slice on the identical order or a paged card loses its price.
    seller.products.alive.not_archived.not_draft
          .includes(:thumbnail_alive, display_asset_previews: { file_attachment: :blob })
          .order(created_at: :desc, id: :desc).offset(offset).limit(limit).map do |product|
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
