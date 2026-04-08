# frozen_string_literal: true

module DiscoverCuratedProducts
  CURATED_PRODUCTS_TIMEOUT_SECONDS = 10

  def taxonomies_for_nav(recommended_products: nil)
    Discover::TaxonomyPresenter.new.taxonomies_for_nav(recommended_products: curated_products.map(&:product))
  end

  def curated_products
    @root_recommended_products ||= begin
                                     Timeout.timeout(CURATED_PRODUCTS_TIMEOUT_SECONDS) do
                                       cart_product_ids = Cart.fetch_by(user: logged_in_user, browser_guid: cookies[:_gumroad_guid])&.cart_products&.alive&.pluck(:product_id) || []
                                       RecommendedProducts::DiscoverService.fetch(purchaser: logged_in_user, cart_product_ids:, recommender_model_name: session[:recommender_model_name])
                                     end
                                   rescue Timeout::Error, StandardError => e
                                     Rails.logger.error("Failed to fetch curated products: #{e.class} - #{e.message}")
                                     []
                                   end
  end
end
