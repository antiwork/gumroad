# frozen_string_literal: true

# Public, render-safe snapshot of a seller's catalog for their custom profile page.
# The page is sandboxed (opaque origin, connect-src 'none'), so it can't fetch at
# render time - we inject this server-side as JSON instead, mirroring how product
# custom HTML has its fields filled in server-side. The seller's HTML/JS reads it to
# render products/posts/pages dynamically, and it refreshes on every page load. Only
# already-public data is included (alive products, profile-visible posts, page names).
class Pages::ProfileData
  MAX_ITEMS = 100
  DESCRIPTION_LIMIT = 200

  def self.build(seller)
    {
      products: products(seller),
      posts: posts(seller),
      pages: pages(seller),
    }
  end

  def self.products(seller)
    seller.products.alive.not_archived.order(created_at: :desc).limit(MAX_ITEMS).map do |product|
      {
        name: product.name,
        url: product.long_url,
        price: product.price_formatted_verbose,
        native_type: product.native_type,
        thumbnail_url: product.thumbnail&.alive&.url,
        description: ActionView::Base.full_sanitizer.sanitize(product.description.to_s).squish.truncate(DESCRIPTION_LIMIT),
      }
    end
  end

  def self.posts(seller)
    seller.installments.visible_on_profile.order(published_at: :desc).limit(MAX_ITEMS).map do |post|
      {
        name: post.name,
        url: post.full_url,
        published_at: post.published_at&.iso8601,
      }
    end
  end

  def self.pages(seller)
    (seller.seller_profile.json_data["tabs"] || []).filter_map do |tab|
      { name: tab["name"] } if tab["name"].present?
    end
  end
end
