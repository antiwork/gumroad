# frozen_string_literal: true

class Wishlists::BaseController < ApplicationController
  include CustomDomainConfig, DiscoverCuratedProducts, FindWishlist

  before_action :authenticate_user!, except: :show
  after_action :verify_authorized, except: :show
  before_action :hide_layouts, only: :show
end
