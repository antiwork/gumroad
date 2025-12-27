# frozen_string_literal: true

class UtmLinksController < Sellers::BaseController
  before_action :set_utm_link, only: %i[edit update destroy]
  before_action :authorize_utm_link, only: %i[edit update destroy]

  layout "inertia"

  def index
    authorize UtmLink

    presenter = PaginatedUtmLinksPresenter.new(
      seller: current_seller,
      query: index_params[:query],
      page: index_params[:page],
      sort: index_params[:sort]
    )

    render inertia: "UtmLinks/Index", props: presenter.props.merge(
      query: index_params[:query],
      sort: index_params[:sort]
    )
  end

  def new
    authorize UtmLink

    presenter = UtmLinkPresenter.new(seller: current_seller)
    render inertia: "UtmLinks/New", props: presenter.new_page_react_props(copy_from: params[:copy_from])
  end

  def create
    authorize UtmLink

    save_utm_link(
      success_message: "Link created!",
      error_redirect_path: new_utm_link_dashboard_path
    )
  end

  def edit
    presenter = UtmLinkPresenter.new(seller: current_seller, utm_link: @utm_link)
    render inertia: "UtmLinks/Edit", props: presenter.edit_page_react_props
  end

  def update
    return e404 if @utm_link.deleted?

    save_utm_link(
      success_message: "Link updated!",
      error_redirect_path: edit_utm_link_dashboard_path(@utm_link.external_id)
    )
  end

  def destroy
    @utm_link.mark_deleted!
    redirect_to utm_links_dashboard_path, notice: "Link deleted!", status: :see_other
  end

  private
    def set_title
      @title = "UTM Links"
    end

    def set_utm_link
      @utm_link = current_seller.utm_links.find_by_external_id(params[:id])
      e404 unless @utm_link
    end

    def authorize_utm_link
      authorize @utm_link
    end

    def index_params
      params.permit(:query, :page, :key, :direction).tap do |p|
        if p[:key].present? && p[:direction].present?
          p[:sort] = { key: p[:key], direction: p[:direction] }
        end
      end
    end

    def permitted_params
      params.require(:utm_link).permit(
        :title, :target_resource_type, :target_resource_id,
        :permalink, :utm_source, :utm_medium, :utm_campaign,
        :utm_term, :utm_content
      ).merge(
        ip_address: request.remote_ip,
        browser_guid: cookies[:_gumroad_guid]
      )
    end

    def save_utm_link(success_message:, error_redirect_path:)
      SaveUtmLinkService.new(seller: current_seller, params: permitted_params, utm_link: @utm_link).perform
      redirect_to utm_links_dashboard_path, notice: success_message, status: :see_other
    rescue ActiveRecord::RecordInvalid => e
      error = e.record.errors.first
      redirect_to error_redirect_path, inertia: { errors: { error.attribute => [error.message] } }, alert: error.message
    end
end
