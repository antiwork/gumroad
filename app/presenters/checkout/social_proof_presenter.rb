# frozen_string_literal: true

class Checkout::SocialProofPresenter
  include CheckoutDashboardHelper

  PER_PAGE = 10

  attr_reader :pundit_user

  def initialize(pundit_user:)
    @pundit_user = pundit_user
  end

  def social_proof_props
    seller = pundit_user.seller
    products = pundit_user.seller.products.visible.map do |product|
      {
        id: product.external_id,
        name: product.name,
        archived: product.archived?,
        currency_type: product.price_currency_type,
        url: product.long_url,
        is_tiered_membership: product.is_tiered_membership?,
      }
    end

    # Get the first page of social proof widgets (consistent with pagination)
    total_widgets = seller.social_proof_widgets.count
    first_page_widgets = seller.social_proof_widgets.limit(PER_PAGE).map { |widget| social_proof_widget_props(widget) }
    total_pages = (total_widgets.to_f / PER_PAGE).ceil

    {
      pages:,
      user: {
        display_offer_code_field: seller.display_offer_code_field?,
        recommendation_type: seller.recommendation_type,
        tipping_enabled: seller.tipping_enabled?,
      },
      custom_fields: seller.custom_fields.not_is_post_purchase.map(&:as_json),
      products:,
      social_proof_widgets: first_page_widgets,
      pagination: { page: 1, pages: total_pages, totalItems: total_widgets },
    }
  end

  def social_proof_widget_props(widget)
    analytics = widget.analytics_summary

    widget.as_json(
      only: [
        :id,
        :name,
        :title,
        :description,
        :cta_text,
        :cta_type,
        :image_type,
        :image_url,
        :icon_name,
        :icon_color,
        :universal
      ]
    ).merge(
      product_ids: widget.links.map(&:external_id),
      can_update: Pundit.policy!(pundit_user, [:checkout, :social_proof]).update?,
      clicks: analytics[:clicks],
      conversion_rate: analytics[:conversion_rate],
      revenue: analytics[:revenue],
      status: analytics[:status]
    )
  end
end
