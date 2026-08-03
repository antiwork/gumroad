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
      modified_params = params.dup
      modified_params[:target_resource_id] = resolved_target_resource_id(params[:target_resource_type], params[:target_resource_id])

      modified_params.slice(:title, :target_resource_type, :target_resource_id, :permalink, :utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content, :ip_address, :browser_guid)
    end

    # Only decrypting the caller-supplied id (the pre-fix behavior) lets a seller point a UTM
    # link at another seller's product or post, since SaveUtmLinkService never checked
    # ownership before create. Resolve through the seller's own association instead so a
    # foreign or nonexistent id becomes nil and fails the model's presence validation.
    def resolved_target_resource_id(target_resource_type, target_resource_id)
      return if target_resource_id.blank?

      case target_resource_type
      when "product_page"
        seller.links.find_by_external_id(target_resource_id)&.id
      when "post_page"
        seller.installments.find_by_external_id(target_resource_id)&.id
      end
    end

    def params_permitted_for_update
      params.slice(:title, :utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content)
    end
end
