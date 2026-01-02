# frozen_string_literal: true

class UtmLinksController < Sellers::BaseController
  before_action :set_utm_link, only: [:edit, :update, :destroy]
  before_action :authorize_user
  layout "inertia"

  def index
    route_params = index_route_params_helper
    render inertia: "UtmLinks/Index",
           props: {
             utm_links_props: -> {
               PaginatedUtmLinksPresenter.new(
                seller: current_seller,
                query: route_params[:query],
                page: route_params[:page],
                sort: { key: route_params[:key], direction: route_params[:direction] }.compact
              ).props
             },
             utm_links_stats: InertiaRails.merge do
               if route_params[:ids].present?
                 utm_link_ids = current_seller.utm_links.by_external_ids(route_params[:ids]).pluck(:id)
                 UtmLinksStatsPresenter.new(seller: current_seller, utm_link_ids:).props
               else
                 {}
               end
             end,
           }
  end

  def new
    utm_link_presenter = UtmLinkPresenter.new(seller: current_seller)
    render inertia: "UtmLinks/New", props: {
      utm_link: -> { utm_link_presenter.new_page_react_props(copy_from: params[:copy_from]) },
      context: -> { utm_link_presenter.utm_link_form_context_props }
    }
  end

  def edit
    utm_link_presenter = UtmLinkPresenter.new(seller: current_seller, utm_link: @utm_link)
    render inertia: "UtmLinks/Edit", props: { utm_link: utm_link_presenter.edit_page_react_props, context: utm_link_presenter.utm_link_form_context_props }
  end

  def create
    save_utm_link
  end

  def update
    return redirect_to dashboard_utm_links_path, status: :see_other, alert: "Link not found!" if @utm_link.deleted?
    save_utm_link
  end

  def destroy
    @utm_link.mark_deleted!
    redirect_to dashboard_utm_links_path(index_route_params_helper.except(:ids).compact), notice: "Link deleted!", status: :see_other
  end

  private
    def index_route_params_helper
      params.permit(:query, :page, :key, :direction, ids: []).to_h.compact
    end

    def set_utm_link
      @utm_link = current_seller.utm_links.find_by_external_id(params[:id]) || e404
    end

    def authorize_user
      if @utm_link.present?
        authorize(@utm_link)
      else
        authorize(UtmLink)
      end
    end

    def utm_link_params
      params.require(:utm_link).permit(:title, :target_resource_type, :target_resource_id, :permalink, :utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content).merge(
        ip_address: request.remote_ip,
        browser_guid: cookies[:_gumroad_guid]
      )
    end

    def save_utm_link
      SaveUtmLinkService.new(seller: current_seller, params: utm_link_params, utm_link: @utm_link).perform

      redirect_to dashboard_utm_links_path, notice: @utm_link ? "Link updated!" : "Link created!", status: :see_other
    rescue ActiveRecord::RecordInvalid => e
      error_path = @utm_link ? edit_dashboard_utm_link_path(@utm_link.external_id) : new_dashboard_utm_link_path(copy_from: params[:copy_from])
      redirect_to error_path, inertia: { errors: e.record.errors }
    end

    def set_title
      @title = "UTM Links"
    end
end
