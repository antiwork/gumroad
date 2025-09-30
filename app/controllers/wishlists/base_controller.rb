# frozen_string_literal: true

class Wishlists::BaseController < ApplicationController
  include CustomDomainConfig, DiscoverCuratedProducts

  before_action :authenticate_user!, except: :show
  after_action :verify_authorized, except: :show
  before_action :hide_layouts, only: :show

  protected
    def find_wishlist
      @wishlist = user_by_domain(request.host).wishlists.alive.find_by_url_slug(params[:id])
      e404 if @wishlist.blank?

      @user = @wishlist.user
      @title = @wishlist.name
      @show_user_favicon = true
    end
end
