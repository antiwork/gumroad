# frozen_string_literal: true

# The editor's version history: every build of a product, and promoting one of them (rollback). Deploys
# come from the CLI and the API, so there is no create here.
class Products::BuildsController < Sellers::BaseController
  before_action :fetch_product

  def index
    render json: { builds: @product.product_builds.reorder(number: :desc).map(&:as_json) }
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
