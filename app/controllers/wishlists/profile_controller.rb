# frozen_string_literal: true

class Wishlists::ProfileController < Wishlists::BaseController
  before_action :find_wishlist, only: :show

  def show
    wishlist_presenter = WishlistPresenter.new(wishlist: @wishlist)

    render inertia: "Wishlists/Profile/Show",
           props: inertia_props(**wishlist_presenter.public_props(request:, pundit_user:))
  end
end
