# frozen_string_literal: true

class OmnibarSearchPresenter
  include Rails.application.routes.url_helpers

  MINIMUM_QUERY_LENGTH = 2
  MAXIMUM_QUERY_LENGTH = 100
  RESULTS_PER_GROUP = 5

  def initialize(pundit_user:, query:)
    @pundit_user = pundit_user
    @query = query.to_s.strip.first(MAXIMUM_QUERY_LENGTH)
  end

  def props
    return { products: [], customers: [], customers_unavailable: false } if query.length < MINIMUM_QUERY_LENGTH

    found_customers = customers
    { products:, customers: found_customers || [], customers_unavailable: found_customers.nil? }
  end

  private
    attr_reader :pundit_user, :query

    def seller = pundit_user.seller

    def products
      return [] unless Pundit.policy!(pundit_user, Link).index?

      seller.products.visible_and_not_archived
        .where("links.name LIKE ?", "%#{Link.sanitize_sql_like(query)}%")
        # A name that starts with the query comes before one that only contains it.
        .order(Arel.sql(Link.sanitize_sql_array(["LOCATE(?, links.name)", query])), created_at: :desc)
        .limit(RESULTS_PER_GROUP)
        .map { |product| { id: product.external_id, name: product.name, url: edit_link_path(product) } }
    end

    # nil when the search index cannot answer, so the bar can say so and still offer products.
    def customers
      return [] unless Pundit.policy!(pundit_user, [:audience, Purchase]).index?

      sales = PurchaseSearchService.search(
        seller:,
        seller_query: query,
        # The customers page's own exclusions: one row per customer-facing sale.
        state: Purchase::NON_GIFT_SUCCESS_STATES,
        exclude_non_original_subscription_purchases: true,
        exclude_giftees: true,
        exclude_bundle_product_purchases: true,
        exclude_commission_completion_purchases: true,
        size: RESULTS_PER_GROUP,
        sort: [{ created_at: { order: :desc } }, { id: { order: :desc } }],
      )

      sales.records.includes(:link, :purchaser).map do |purchase|
        {
          id: purchase.external_id,
          email: purchase.email,
          name: purchase.full_name.try(:strip).presence || purchase.purchaser&.name || "",
          product_name: purchase.link.name,
          url: customer_sale_path(purchase.external_id),
        }
      end
    rescue Elasticsearch::Transport::Transport::Errors::BadRequest => e
      # A query the index rejects is ours to fix; an index that is down is already being paged about.
      ErrorNotifier.notify(e)
      nil
    rescue Faraday::Error, Elasticsearch::Transport::Transport::Error
      nil
    end
end
