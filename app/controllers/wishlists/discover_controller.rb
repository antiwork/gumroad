# frozen_string_literal: true

class Wishlists::DiscoverController < Wishlists::BaseController
  before_action :find_wishlist, only: :show

  def show
    wishlist_presenter = WishlistPresenter.new(wishlist: @wishlist)
    discover_props = { taxonomies_for_nav: }

    render inertia: "Wishlists/Discover/Show",
           props: inertia_props(**wishlist_presenter.public_props(request:, pundit_user:, recommended_by: params[:recommended_by]).merge(discover_props))
  end
end
