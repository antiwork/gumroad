# frozen_string_literal: true

class Api::Internal::UtmLinksController < Api::Internal::BaseController
  before_action :authenticate_user!
  after_action :verify_authorized
  before_action :set_utm_link, only: [:edit, :update, :destroy]
  before_action :authorize_user, only: [:edit, :update, :destroy]

  def index
    authorize UtmLink

    json = PaginatedUtmLinksPresenter.new(
      seller: current_seller,
      query: index_params[:query],
      page: index_params[:page],
      sort: index_params[:sort]
    ).props

    render json:
  end

  def new
    authorize UtmLink

    render json: UtmLinkPresenter.new(seller: current_seller).new_page_react_props(copy_from: params[:copy_from])
  end

  def create
    authorize UtmLink

    save_utm_link
  end

  def edit
    render json: UtmLinkPresenter.new(seller: current_seller, utm_link: @utm_link).edit_page_react_props
  end

  def update
    return e404_json if @utm_link.deleted?

    save_utm_link
  end

  def destroy
    @utm_link.mark_deleted!

    head :ok
  end

  private
    def index_params
      params.permit(:query, :page, sort: [:key, :direction])
    end

    def set_utm_link
      @utm_link = current_seller.utm_links.find_by_external_id(params[:id])
      e404_json unless @utm_link
    end

    def authorize_user
      authorize @utm_link
    end

    def render_error_response(error, attr_name: nil)
      render json: { error:, attr_name: }, status: :unprocessable_entity
    end

    def permitted_params
      params.require(:utm_link).permit(:title, :target_resource_type, :target_resource_id, :permalink, :utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content).merge(
        ip_address: request.remote_ip,
        browser_guid: cookies[:_gumroad_guid]
      )
    end

    def save_utm_link
      SaveUtmLinkService.new(seller: current_seller, params: permitted_params, utm_link: @utm_link).perform

      head :ok
    rescue ActiveRecord::RecordInvalid => e
      error = e.record.errors.first
      render_error_response(error.message, attr_name: error.attribute)
    end
end
