# frozen_string_literal: true

module DiscoverCuratedProducts
  def taxonomies_for_nav(recommended_products: nil)
    Discover::TaxonomyPresenter.new.taxonomies_for_nav(recommended_products: curated_products.map(&:product))
  end

  def curated_products
    @root_recommended_products ||= begin
                                     cart_product_ids = Cart.fetch_by(user: logged_in_user, browser_guid: cookies[:_gumroad_guid])&.cart_products&.alive&.pluck(:product_id) || []
                                     RecommendedProducts::DiscoverService.fetch(purchaser: logged_in_user, cart_product_ids:, recommender_model_name: session[:recommender_model_name])
                                   end
  end
end
