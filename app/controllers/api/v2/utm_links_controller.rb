# frozen_string_literal: true

# Public API surface for UTM links (gumroad-private#1789): the tracking links sellers manage
# under Analytics → UTM links. List/read plus create/update with the dashboard's own
# validation via SaveUtmLinkService, and disable/enable rather than hard delete — the short
# permalink must keep resolving for material already in the wild, matching the dashboard's
# disable semantics. `destroy` soft-deletes, same as the dashboard's delete.
class Api::V2::UtmLinksController < Api::V2::BaseController
  before_action(only: [:index, :show]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_api_read_scopes.concat([:view_public])) }
  before_action(only: [:create, :update, :destroy, :disable, :enable]) { doorkeeper_authorize! :edit_products }
  before_action :fetch_utm_link, only: %i[show update destroy disable enable]

  def index
    success_with_object(:utm_links, utm_links_scope.order(created_at: :desc, id: :desc))
  end

  def show
    success_with_utm_link(@utm_link)
  end

  def create
    utm_link = SaveUtmLinkService.new(seller: current_resource_owner, params: utm_link_params).perform
    success_with_utm_link(utm_link)
  rescue ActiveRecord::RecordInvalid => e
    error_with_creating_object(:utm_link, e.record)
  end

  def update
    SaveUtmLinkService.new(seller: current_resource_owner, params: utm_link_params, utm_link: @utm_link).perform
    success_with_utm_link(@utm_link.reload)
  rescue ActiveRecord::RecordInvalid => e
    error_with_object(:utm_link, e.record)
  end

  def destroy
    if @utm_link.mark_deleted
      success_with_utm_link
    else
      error_with_utm_link(@utm_link)
    end
  end

  def disable
    @utm_link.mark_disabled!
    success_with_utm_link(@utm_link)
  end

  def enable
    @utm_link.mark_enabled!
    success_with_utm_link(@utm_link)
  end

  private
    def utm_links_scope
      current_resource_owner.utm_links.alive
    end

    def fetch_utm_link
      @utm_link = utm_links_scope.find_by_external_id(params[:id])
      error_with_utm_link if @utm_link.nil?
    end

    def utm_link_params
      params.permit(
        :title,
        :target_resource_type,
        :target_resource_id,
        :utm_source,
        :utm_medium,
        :utm_campaign,
        :utm_term,
        :utm_content
      ).to_h.symbolize_keys.merge(
        ip_address: request.remote_ip,
        browser_guid: cookies[:_gumroad_guid]
      )
    end

    def success_with_utm_link(utm_link = nil)
      success_with_object(:utm_link, utm_link)
    end

    def error_with_utm_link(utm_link = nil)
      error_with_object(:utm_link, utm_link)
    end
end
