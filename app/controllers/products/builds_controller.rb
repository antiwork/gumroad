# frozen_string_literal: true

# The editor's version history: every build of a product, a new build from a zip uploaded in the editor,
# and promoting one of them (rollback).
class Products::BuildsController < Sellers::BaseController
  before_action :fetch_product

  def index
    render json: { builds: @product.product_builds.reorder(number: :desc).map(&:as_json) }
  end

  # The editor uploads to the current seller's attachments, the same place the deploy step accepts.
  def create
    build = ProductBuilds::DeployService.perform(product: @product, seller: current_seller, url: params[:url])
    render json: { build: build.as_json }
  rescue ProductBuilds::DeployService::DeployError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def promote
    build = @product.product_builds.find_by(public_id: params[:id].to_s) || e404
    build.promote!
    head :no_content
  end

  private
    def fetch_product
      @product = Link.visible.find_by(unique_permalink: params[:product_id]) || e404
      authorize @product, :update?
      e404 unless @product.build_player_enabled?
    end
end
