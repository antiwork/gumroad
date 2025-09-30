# frozen_string_literal: true

module FindWishlist
  extend ActiveSupport::Concern

  private
    def find_wishlist
      @wishlist = user_by_domain(request.host).wishlists.alive.find_by_url_slug(params[:id])
      e404 if @wishlist.blank?

      @user = @wishlist.user
      @title = @wishlist.name
      @show_user_favicon = true
    end
end
