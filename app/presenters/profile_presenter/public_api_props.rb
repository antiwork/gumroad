# frozen_string_literal: true

# Public, unauthenticated, read-only JSON representation of a creator's profile —
# the documented payload returned by `GET /:username.json` (the seller's
# public profile page).
#
# This is the read/display counterpart to the rendered profile page: it exposes
# the same public information a visitor sees (name, bio, avatar, social links,
# and the creator's visible profile products) so anyone can build their own
# storefronts, directories, and widgets that stay in sync with the profile.
#
# Hard rules:
#   * PUBLIC — never include seller-private or admin fields (email, balance,
#     tokens, tax info, compliance internals). The bare `User#as_json` this
#     replaces dumped every column; this allowlist fails CLOSED.
#   * Lists only products visible in public profile product sections, mirroring
#     what the profile page renders to a logged-out visitor.
#   * Stable, versioned shape (`api_version`) so integrators can depend on it.
class ProfilePresenter::PublicApiProps
  include Rails.application.routes.url_helpers
  include ActionView::Helpers::OutputSafetyHelper
  include CurrencyHelper

  # Bump when the public shape changes in a backwards-incompatible way.
  API_VERSION = 1

  # Cap the inline product list so the endpoint stays cheap and predictable.
  PRODUCTS_LIMIT = 100
  PRODUCT_ASSOCIATIONS_FOR_VISIBILITY = [
    *ProductPresenter::Card::ASSOCIATIONS,
    { variant_categories_alive: :alive_variants },
    { bundle_products: { product: [:tiers, { variant_categories_alive: :alive_variants }], variant: [] } },
  ].freeze

  def initialize(seller:, seller_custom_domain_url: nil)
    @seller = seller
    @seller_custom_domain_url = seller_custom_domain_url
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
      profile_url: seller.profile_url(custom_domain_url: seller_custom_domain_url),
      subdomain: seller.subdomain,
      twitter_handle: seller.twitter_handle,
      is_verified: !!seller.verified,

      # Products visible in public profile product sections.
      products: products_props,
    }
  end

  private
    attr_reader :seller, :seller_custom_domain_url

    def products_props
      products = visible_profile_products
      latest_sale_ids_by_product_id = latest_sale_ids_by_product_id(products)

      products.map do |product|
        card_props = ProductPresenter.card_for_web(product:, show_seller: false, compute_description: false, compute_inventory: false)

        {
          id: product.external_id,
          permalink: product.general_permalink,
          name: product.name,
          native_type: product.native_type,
          url: product_url(product),
          thumbnail_url: product.thumbnail&.alive&.url,
          price_cents: card_props[:price_cents],
          currency_code: card_props[:currency_code],
          price_formatted: product_card_formatted_price(
            price: card_props[:price_cents],
            currency_code: card_props[:currency_code],
            is_pay_what_you_want: card_props[:is_pay_what_you_want],
            recurrence: card_props[:recurrence],
            duration_in_months: card_props[:duration_in_months],
          ).to_s,
          is_pay_what_you_want: card_props[:is_pay_what_you_want],
          is_recurring_billing: product.is_recurring_billing,
          ratings: product.display_product_reviews? ? product.rating_stats : nil,
          sales_count: ProductPresenter.cached_sales_count(product, latest_sale_id: latest_sale_ids_by_product_id[product.id]),
        }
      end
    end

    def latest_sale_ids_by_product_id(products)
      return {} if products.blank?

      Purchase.where(link_id: products.map(&:id)).group(:link_id).maximum(:id)
    end

    def product_url(product)
      return product.long_url if seller_custom_domain_url.blank?

      uri = URI.parse(seller_custom_domain_url)
      options = {
        host: uri.host,
        protocol: "#{uri.scheme}://",
      }
      options[:port] = uri.port if uri.port != uri.default_port

      short_link_url(product.general_permalink, **options)
    end

    def visible_profile_products
      products = []
      seen_product_ids = {}

      ordered_profile_product_sections.each do |section|
        visible_products_for_section(section).each do |product|
          next if seen_product_ids[product.id]

          products << product
          seen_product_ids[product.id] = true
          return products if products.size >= PRODUCTS_LIMIT
        end
      end

      products
    end

    def visible_products_for_section(section)
      product_ids = Link.search(
        Link.search_options(
          sort: section.default_product_sort,
          section:,
          is_alive_on_profile: true,
          user_id: seller.id,
          size: PRODUCTS_LIMIT,
        )
      ).records.ids.map(&:to_i)
      products_by_id = Link.includes(PRODUCT_ASSOCIATIONS_FOR_VISIBILITY).where(id: product_ids).index_by(&:id)

      product_ids.filter_map { products_by_id[_1] }
                 .reject { |product| product.hide_sold_out_variants? && product.remaining_for_sale_count == 0 }
    end

    def ordered_profile_product_sections
      sections = seller.seller_profile_products_sections.on_profile.to_a
      section_ids = profile_tab_section_ids
      return [] if section_ids.blank?

      sections_by_id = sections.index_by(&:id)
      section_ids.uniq.filter_map { sections_by_id[_1] }
    end

    def profile_tab_section_ids
      tabs = Array(seller.seller_profile&.json_data&.fetch("tabs", nil) || seller.seller_profile&.json_data&.fetch(:tabs, nil))
      tabs.flat_map { |tab| Array(tab["sections"] || tab[:sections]) }.map(&:to_i)
    end
end
