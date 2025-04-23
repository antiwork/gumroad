# frozen_string_literal: true

class Checkout::SocialProofWidgetsPresenter
  include CheckoutDashboardHelper

  attr_reader :pundit_user, :social_proof_widgets, :pagination

  def initialize(pundit_user:, social_proof_widgets:, pagination:)
    @pundit_user = pundit_user
    @social_proof_widgets = social_proof_widgets
    @pagination = pagination
  end

  def social_proof_widgets_props
    {
      pages:,
      social_proof_widgets: social_proof_widgets.includes(
          :links,
          :metric,
          :conversions,
        ).map(&:as_json),
      pagination:,
      products: pundit_user.seller.products
        .visible_and_not_archived
        .map { product_props(_1) }
    }
  end

  private
    def product_props(product)
      {
        id: product.external_id,
        name: product.name,
        native_type: product.native_type
      }
    end
end
