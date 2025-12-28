# frozen_string_literal: true

class UtmLinksController < Sellers::BaseController
  before_action :set_utm_link, only: [:edit, :update, :destroy]
  before_action :authorize_utm_link
  layout "inertia"

  def index
    route_params = index_route_params_helper

    render inertia: "Analytics/UtmLinks/Index",
           props: {
             utm_links_props: PaginatedUtmLinksPresenter.new(
               seller: current_seller,
               query: route_params[:query],
               page: route_params[:page],
               sort: { key: route_params[:key], direction: route_params[:direction] }.compact
             ).props,
             utm_links_stats: InertiaRails.merge { fetch_utm_links_stats(route_params[:ids]) },
           }
  end

  def new
    utm_link_presenter = UtmLinkPresenter.new(seller: current_seller)

    render inertia: "Analytics/UtmLinks/New", props: {
      **utm_link_presenter.new_page_react_props(copy_from: params[:copy_from]),
      additional_metadata: InertiaRails.optional { utm_link_presenter.new_additional_metadata_props },
    }
  end

  def edit
    render inertia: "Analytics/UtmLinks/Edit", props: UtmLinkPresenter.new(seller: current_seller, utm_link: @utm_link).edit_page_react_props
  end

  def create
    save_utm_link
  end

  def update
    return redirect_to utm_links_dashboard_path, status: :see_other, alert: "Link not found!" if @utm_link.deleted?

    save_utm_link
  end

  def destroy
    @utm_link.mark_deleted!

    redirect_to utm_links_dashboard_path(index_route_params_helper.except(:ids).compact), notice: "Link deleted!", status: :see_other
  end

  private
    def index_route_params_helper
      params.permit(:query, :page, :key, :direction, ids: []).to_h.compact
    end

    def fetch_utm_links_stats(ids)
      return {} unless ids.present?

      ids_array = ids.is_a?(Array) ? ids : ids.split(",").compact
      utm_link_ids = current_seller.utm_links.by_external_ids(ids_array).pluck(:id)
      UtmLinksStatsPresenter.new(seller: current_seller, utm_link_ids:).props
    end

    def set_utm_link
      @utm_link = current_seller.utm_links.find_by_external_id(params[:id])
      head :not_found unless @utm_link
    end

    def authorize_utm_link
      authorize(@utm_link || UtmLink)
    end

    def utm_link_params
      params.require(:utm_link).permit(:title, :target_resource_type, :target_resource_id, :permalink, :utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content).merge(
        ip_address: request.remote_ip,
        browser_guid: cookies[:_gumroad_guid]
      )
    end

    def save_utm_link
      SaveUtmLinkService.new(seller: current_seller, params: utm_link_params, utm_link: @utm_link).perform

      redirect_to utm_links_dashboard_path, notice: @utm_link ? "Link updated!" : "Link created!", status: :see_other
    rescue ActiveRecord::RecordInvalid => e
      error = e.record.errors.first
      error_key = error.attribute.to_s

      correct_path_on_error = @utm_link ? edit_dashboard_utm_link_path(@utm_link.external_id) : new_dashboard_utm_link_path(copy_from: params[:copy_from])
      redirect_to correct_path_on_error, inertia: { errors: { error_key => [error.message] } }
    end

    def set_title
      @title = "UTM Links"
    end
end
