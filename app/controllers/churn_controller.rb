# frozen_string_literal: true

class ChurnController < Sellers::BaseController
  layout "inertia"

  def show
    authorize :churn

    LargeSeller.create_if_warranted(current_seller)

    service = CreatorAnalytics::Churn.new(user: current_seller, params: params)

    render inertia: "Churn/Show",
           props: {
             has_subscription_products: service.has_subscription_products?
             churn_data: InertiaRails.optional { service.fetch_churn_data }
           }
  end
end
