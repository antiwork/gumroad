# frozen_string_literal: true

class Products::RemainingCallAvailabilitiesController < ApplicationController
  include FetchProductByUniquePermalink

  before_action :fetch_product_by_unique_permalink

  def index
    if @product.native_type == Link::NATIVE_TYPE_CALL
      render json: { call_availabilities: @product.remaining_call_availabilities }
    else
      head :not_found
    end
  end
end
