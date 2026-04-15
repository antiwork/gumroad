# frozen_string_literal: true

class UtmLinkPresenter
  include CurrencyHelper

  def initialize(seller:, utm_link: nil)
    @seller = seller
    @utm_link = utm_link
  end

  def new_page_react_props(copy_from: nil)
    reference_utm_link = seller.utm_links.alive.find_by_external_id(copy_from) if copy_from.present?
    context_props = utm_link_form_context_props

    if reference_utm_link.present?
      utm_link_props = self.class.new(seller:, utm_link: reference_utm_link).utm_link_props.except(:id)
      utm_link_props[:short_url] = context_props[:short_url]
    end

    { context: context_props, utm_link: utm_link_props }
  end

  def edit_page_react_props
    { context: utm_link_form_context_props, utm_link: utm_link_props }
  end

  def utm_link_props
    {
      id: utm_link.external_id,
      title: utm_link.title,
      short_url: utm_link.short_url,
      utm_url: utm_link.utm_url,
      created_at: utm_link.created_at.iso8601,
      source: utm_link.utm_source,
      medium: utm_link.utm_medium,
      campaign: utm_link.utm_campaign,
      term: utm_link.utm_term,
      content: utm_link.utm_content,
      clicks: utm_link.unique_clicks,
      destination_option: destination_option(type: utm_link.target_resource_type, resource: utm_link.target_resource, add_label_prefix: false),
      sales_count: utm_link.respond_to?(:sales_count) ? utm_link.sales_count : nil,
      revenue_cents: utm_link.respond_to?(:revenue_cents) ? utm_link.revenue_cents : nil,
      conversion_rate: utm_link.respond_to?(:conversion_rate) ? utm_link.conversion_rate.round(4) : nil,
    }
  end

  def new_additional_metadata_props
    { new_permalink: UtmLink.generate_permalink }
  end

  private
    attr_reader :seller, :utm_link

    def utm_link_form_context_props
      products = *seller.products.includes(:user).alive.order(:name).map { destination_option(type: UtmLink.target_resource_types[:product_page], resource: _1) }
      posts = *seller.installments.audience_type.shown_on_profile.not_workflow_installment.published.includes(:seller).order(:name).map { destination_option(type: UtmLink.target_resource_types[:post_page], resource: _1) }
      utm_fields_values = seller.utm_links.alive.pluck(:utm_campaign, :utm_medium, :utm_source, :utm_term, :utm_content)
        .each_with_object({
                            campaigns: Set.new,
                            mediums: Set.new,
                            sources: Set.new,
                            terms: Set.new,
                            contents: Set.new
                          }) do |(campaign, medium, source, term, content), result|
        result[:campaigns] << campaign if campaign.present?
        result[:mediums] << medium if medium.present?
        result[:sources] << source if source.present?
        result[:terms] << term if term.present?
        result[:contents] << content if content.present?
      end.transform_values(&:to_a)

      {
        destination_options: [
          destination_option(type: UtmLink.target_resource_types[:profile_page]),
          destination_option(type: UtmLink.target_resource_types[:subscribe_page]),
          *products,
          *posts,
        ],
        short_url: utm_link.present? ? utm_link.short_url : UtmLink.new(permalink: UtmLink.generate_permalink).short_url,
        utm_fields_values:,
      }
    end

    def destination_option_id(resource_type, resource_external_id)
      return resource_type if resource_type.in?(target_resource_types.values_at(:profile_page, :subscribe_page))

      [resource_type, resource_external_id].compact_blank.join("-")
    end

    def destination_option(type:, resource: nil, add_label_prefix: true)
      external_id = resource.external_id if resource.present?
      id = destination_option_id(type, external_id)

      case type
      when target_resource_types[:product_page]
        { id:, label: "#{add_label_prefix ? "Product — " : ""}#{resource.name}", url: resource.long_url }
      when target_resource_types[:post_page]
        { id:, label: "#{add_label_prefix ? "Post — " : ""}#{resource.name}", url: resource.full_url }
      when target_resource_types[:profile_page]
        { id:, label: "Profile page", url: seller.profile_url }
      when target_resource_types[:subscribe_page]
        { id:, label: "Subscribe page", url: Rails.application.routes.url_helpers.custom_domain_subscribe_url(host: seller.subdomain_with_protocol) }
      end
    end

    def target_resource_types = UtmLink.target_resource_types
end
