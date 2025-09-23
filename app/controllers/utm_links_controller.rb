# frozen_string_literal: true

class UtmLinksController < Sellers::BaseController
  before_action :set_body_id_as_app

  def index
    authorize UtmLink

    query = params[:query]
    page = params[:page]&.to_i || 1
    sort_key = params[:key]
    sort_direction = params[:direction] || "desc"

    sort = if sort_key.present?
      { key: sort_key, direction: sort_direction }
    else
      { key: "date", direction: "desc" }
    end

    utm_links_data = PaginatedUtmLinksPresenter.new(
      seller: current_seller,
      query: query,
      page: page,
      sort: sort
    ).props

    context_data = UtmLinkPresenter.new(seller: current_seller).new_page_react_props

    render inertia: "UtmLinks/index", props: {
      utm_links_props: {
        utm_links: utm_links_data[:utm_links],
        pagination: utm_links_data[:pagination],
        context: context_data[:context]
      }
    }
  end

  def new
    authorize UtmLink

    copy_from = params[:copy_from]
    utm_link_data = UtmLinkPresenter.new(seller: current_seller).new_page_react_props(copy_from: copy_from)

    render inertia: "UtmLinks/index", props: {
      utm_links_props: {
        context: utm_link_data[:context],
        utm_link: utm_link_data[:utm_link],
        copy_from: copy_from
      }
    }
  end

  def edit
    authorize UtmLink

    utm_link = current_seller.utm_links.find_by_external_id(params[:id])
    return head :not_found unless utm_link

    utm_link_data = UtmLinkPresenter.new(seller: current_seller, utm_link: utm_link).edit_page_react_props

    render inertia: "UtmLinks/index", props: {
      utm_links_props: {
        context: utm_link_data[:context],
        utm_link: utm_link_data[:utm_link]
      }
    }
  end

  private
    def set_title
      @title = "UTM Links"
    end
end
