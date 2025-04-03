# frozen_string_literal: true

class SaveUtmLinkService
  def initialize(seller:, params:, utm_link: nil)
    @seller = seller
    @params = params
    @utm_link = utm_link
  end

  def perform
    if utm_link.present?
      utm_link.update!(params_permitted_for_update)
    else
      seller.utm_links.create!(params_permitted_for_create)
    end
  end

  private
    attr_reader :seller, :params, :utm_link

    def params_permitted_for_create
      target_resource_id = params[:target_resource_id]
      modified_params = params.dup

      if target_resource_id.present?
        target_resource_id = ObfuscateIds.decrypt(target_resource_id)
        modified_params.merge!(target_resource_id:)
      end

      modified_params.slice(:title, :target_resource_type, :target_resource_id, :permalink, :utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content, :ip_address, :browser_guid)
    end

    def params_permitted_for_update
      params.slice(:title, :utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content)
    end
end
