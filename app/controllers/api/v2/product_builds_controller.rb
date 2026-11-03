# frozen_string_literal: true

# Deploy pipeline for hosted web builds (games, interactive courses). The caller uploads
# a zip through POST /v2/files/presign + /complete, then `deploy` copies it into an
# immutable, numbered build. Nothing reaches buyers until `promote`.
class Api::V2::ProductBuildsController < Api::V2::BaseController
  before_action { doorkeeper_authorize! :edit_products }
  before_action :fetch_product
  before_action :set_build, only: [:show, :promote, :select_demo, :unselect_demo]

  def index
    render_response(true, builds: @product.product_builds.map(&:as_json))
  end

  def show
    render_response(true, build: @build.as_json)
  end

  def deploy
    build = ProductBuilds::DeployService.perform(product: @product, seller: current_resource_owner, url: params[:url])
    render_response(true, build: build.as_json)
  rescue ProductBuilds::DeployService::DeployError => e
    render_response(false, message: e.message)
  rescue Aws::S3::Errors::ServiceError => e
    error_400(e.message)
  end

  def promote
    @build.promote!
    render_response(true, build: @build.reload.as_json)
  end

  def select_demo
    return render_response(false, message: "This build's zip could not be unpacked, so it cannot play. Deploy a fixed zip as a new build.") if @build.site_unpack_error.present?
    return render_response(false, message: "This build is what buyers get. Deploy a separate build to use as the demo.") if @build.purchased_version?

    @build.select_as_demo!
    render_response(true, build: @build.reload.as_json)
  end

  def unselect_demo
    @build.unselect_as_demo!
    render_response(true, build: @build.as_json)
  end

  private
    def set_build
      @build = @product.product_builds.find_by(public_id: params[:id].to_s) || error_with_object(:build, nil)
    end
end
