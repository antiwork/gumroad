# frozen_string_literal: true

class UtmLinksController < Sellers::BaseController
  include Pagy::Backend

  before_action :set_utm_link, only: [:edit, :update, :destroy]

  layout "inertia"

  def index
    authorize UtmLink

    render inertia: "UtmLinks/Index", props: {
      **paginated_utm_links_props,
      query: index_params[:query],
      sort: index_params[:sort]
    }
  end

  def new
    authorize UtmLink

    render inertia: "UtmLinks/New", props: new_page_props
  end

  def create
    authorize UtmLink

    save_utm_link(
      success_message: "Link created!",
      error_redirect_path: new_utm_links_dashboard_path
    )
  end

  def edit
    authorize @utm_link

    render inertia: "UtmLinks/Edit", props: edit_page_props
  end

  def update
    authorize @utm_link

    if @utm_link.deleted?
      redirect_to utm_links_dashboard_index_path, alert: "Link not found"
      return
    end

    save_utm_link(
      success_message: "Link updated!",
      error_redirect_path: edit_utm_links_dashboard_path(@utm_link)
    )
  end

  def destroy
    authorize @utm_link

    @utm_link.mark_deleted!
    redirect_to utm_links_dashboard_index_path, notice: "Link deleted!"
  end

  def unique_permalink
    authorize UtmLink, :new?

    render json: { permalink: UtmLink.generate_permalink }
  end

  private
    def set_title
      @title = "UTM Links"
    end

    def set_utm_link
      @utm_link = current_seller.utm_links.find_by_external_id(params[:id])
      e404 unless @utm_link
    end

    def index_params
      {
        query: params[:query],
        page: params[:page],
        sort: extract_sort_params
      }
    end

    def extract_sort_params
      key = params[:key]
      direction = params[:direction]

      return nil unless %w[link date source medium campaign clicks sales_count revenue_cents conversion_rate].include?(key)

      { key: key, direction: direction == "desc" ? "desc" : "asc" }
    end

    def paginated_utm_links_props
      PaginatedUtmLinksPresenter.new(
        seller: current_seller,
        query: index_params[:query],
        page: index_params[:page],
        sort: index_params[:sort]
      ).props
    end

    def new_page_props
      UtmLinkPresenter.new(seller: current_seller).new_page_react_props(copy_from: params[:copy_from])
    end

    def edit_page_props
      UtmLinkPresenter.new(seller: current_seller, utm_link: @utm_link).edit_page_react_props
    end

    def permitted_params
      params.require(:utm_link).permit(
        :title,
        :target_resource_type,
        :target_resource_id,
        :permalink,
        :utm_source,
        :utm_medium,
        :utm_campaign,
        :utm_term,
        :utm_content
      ).merge(
        ip_address: request.remote_ip,
        browser_guid: cookies[:_gumroad_guid]
      )
    end

    def save_utm_link(success_message:, error_redirect_path:)
      SaveUtmLinkService.new(
        seller: current_seller,
        params: permitted_params,
        utm_link: @utm_link
      ).perform

      redirect_to utm_links_dashboard_index_path, notice: success_message, status: :see_other
    rescue ActiveRecord::RecordInvalid => e
      error = e.record.errors.first
      redirect_to error_redirect_path, inertia: { errors: { "utm_link.#{error.attribute}" => error.message } }
    end
end
