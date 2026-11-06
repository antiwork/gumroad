# frozen_string_literal: true

# A product's public demo build (ProductBuild.demo_for): the page an X player card shows, and the link from it
# to the product page. Each logs one line, so plays and click-throughs to the product can be counted.
class ProductBuildDemosController < ApplicationController
  layout "inertia", only: :show

  before_action :set_build
  # A demo is reached from an X card or the product page, never from search.
  before_action :set_noindex_header

  def show
    override_content_security_policy_directives(frame_ancestors: ["'self'", *ProductBuild::DEMO_FRAME_ANCESTORS])
    log_demo_event("show")
    set_meta_tag(title: @product.name)

    render inertia: "ProductBuildDemos/Show", props: {
      title: @product.name,
      # The trailing slash makes the build's relative file paths resolve under the grant.
      frame_url: "#{request.path.chomp("/")}/#{@build.demo_grant}/",
      product_url: product_build_demo_product_path(@product.external_id),
    }
  end

  def product
    log_demo_event("product")
    redirect_to @product.long_url, allow_other_host: true
  end

  private
    def set_build
      @product = Link.find_by_external_id(params[:id])
      @build = @product && ProductBuild.demo_for(@product)
      e404 unless @build
    end

    # `framed` tells a card on X web (an iframe) from the X app's in-app browser (a top-level page).
    def log_demo_event(event)
      payload = { event:, product_id: @product.id, seller_id: @product.user_id, framed: request.headers["Sec-Fetch-Dest"] == "iframe" }
      Rails.logger.info("[ProductBuildDemo] #{payload.to_json}")
    end
end
