# frozen_string_literal: true

# Public, unauthenticated, read-only JSON representation of a creator's profile —
# the documented payload returned by `GET /:username.json` (the seller's
# public profile page).
#
# This is the read/display counterpart to the rendered profile page: it exposes
# the same public information a visitor sees (name, bio, avatar, social links,
# and the creator's published products) so anyone can build their own
# storefronts, directories, and widgets that stay in sync with the profile.
#
# Hard rules:
#   * PUBLIC — never include seller-private or admin fields (email, balance,
#     tokens, tax info, compliance internals). The bare `User#as_json` this
#     replaces dumped every column; this allowlist fails CLOSED.
#   * Lists only published, non-archived, non-deleted products, mirroring what
#     the profile page renders to a logged-out visitor.
#   * Stable, versioned shape (`api_version`) so integrators can depend on it.
class ProfilePresenter::PublicApiProps
  # Bump when the public shape changes in a backwards-incompatible way.
  API_VERSION = 1

  # Cap the inline product list so the endpoint stays cheap and predictable.
  PRODUCTS_LIMIT = 100

  def initialize(seller:)
    @seller = seller
  end

  def props
    {
      api_version: API_VERSION,

      # Identity
      id: seller.external_id,
      username: seller.username,
      name: seller.name_or_username,
      bio: seller.bio.presence,
      avatar_url: seller.avatar_url,
      profile_url: seller.profile_url,
      subdomain: seller.subdomain,
      twitter_handle: seller.twitter_handle,
      is_verified: !!seller.verified,

      # Published products (public, mirrors the profile page)
      products: products_props,
    }
  end

  private
    attr_reader :seller

    def products_props
      published_products.map do |product|
        {
          id: product.external_id,
          permalink: product.unique_permalink,
          name: product.name,
          native_type: product.native_type,
          url: product.long_url,
          thumbnail_url: product.thumbnail&.alive&.url,
          price_cents: product.price_cents,
          currency_code: product.price_currency_type.downcase,
          price_formatted: product.price_formatted_verbose,
          is_pay_what_you_want: product.customizable_price?,
          is_recurring_billing: product.is_recurring_billing,
          ratings: product.display_product_reviews? ? product.rating_stats : nil,
          sales_count: product.should_show_sales_count? ? product.successful_sales_count : nil,
        }
      end
    end

    def published_products
      seller.products
            .alive
            .not_archived
            .order(created_at: :desc)
            .limit(PRODUCTS_LIMIT)
    end
end
