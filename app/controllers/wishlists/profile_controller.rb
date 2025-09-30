# frozen_string_literal: true

class Wishlists::ProfileController < Wishlists::BaseController
  def show
    find_wishlist
    wishlist_presenter = WishlistPresenter.new(wishlist: @wishlist)

    render inertia: "Profile/WishlistPage",
           props: inertia_props(**wishlist_presenter.public_props(request:, pundit_user:))
  end
end
