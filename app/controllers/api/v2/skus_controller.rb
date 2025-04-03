# frozen_string_literal: true

class Api::V2::SkusController < Api::V2::BaseController
  before_action -> { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes.concat([:view_public])) }
  before_action :fetch_product

  def index
    skus = if @product.skus_enabled?
      @product.skus.alive.not_is_default_sku.exists? ? @product.skus.alive.not_is_default_sku : @product.skus.alive.is_default_sku
    elsif @product.is_physical?
      @product.alive_variants
    else
      []
    end
    success_with_object(:skus, skus)
  end
end
